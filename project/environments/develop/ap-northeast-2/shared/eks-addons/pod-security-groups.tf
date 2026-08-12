################################################################################
# Security Groups for Pods — Pod 전용 보안 그룹
#
# SGP(ENABLE_POD_ENI)를 켜면 SecurityGroupPolicy에 매칭된 Pod가 자기 전용 브랜치 ENI를 받고,
# 그 ENI에 여기서 정의한 SG가 붙는다. 노드 SG를 공유하던 구조에서 벗어나 Pod 단위로 통제된다.
#
# [배치 위치] rds root가 아니라 이 root가 소유한다. RDS SG의 inbound가 이 SG를 참조하므로
# 소유권을 rds에 두면 GitOps Bridge payload를 조립하는 이 root가 rds root를 역참조해야 한다 —
# 플랫폼 애드온이 워크로드 root에 의존하는 방향이라 keda.tf와 동일한 이유로 피한다.
# 앞으로 ElastiCache 등 다른 데이터스토어가 생겨도 이 SG를 재사용한다.
#
# [매니페스트로 전달되는 값] SecurityGroupPolicy CR의 spec.securityGroups.groupIds에 이 SG의
# ID가 필요한데, ID는 apply 시점에 정해지고 teardown/재provision마다 바뀐다. 매니페스트에
# 하드코딩하면 재생성할 때마다 조용히 깨지므로 gitops-bridge-registry.tf의 payload에 실어
# Hub의 cluster Secret annotation을 거쳐 ApplicationSet이 읽게 한다 (karpenter_node_iam_role_name과 동일 경로).
################################################################################

resource "aws_security_group" "pod_rds_access" {
  # name이 아니라 name_prefix를 쓴다. SG 이름은 VPC 내에서 유일해야 하는데, description처럼
  # Update API가 없는 속성을 바꾸면 SG가 ForceNew로 재생성된다 — 이때 create_before_destroy는
  # 기존 SG가 살아있는 상태에서 신규를 먼저 만들려 하므로 이름이 고정이면 InvalidGroup.Duplicate로
  # apply가 통째로 실패한다. 참조는 전부 ID 기반이라 이름이 랜덤 접미사를 가져도 무방하고,
  # 사람이 식별하는 값은 Name 태그가 담당한다.
  name_prefix = "${local.cluster_name}-pod-rds-access-"
  description = "Pod-level security group granting RDS access via EKS Security Groups for Pods"
  vpc_id      = local.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.cluster_name}-pod-rds-access"
  }
}

# ── egress ────────────────────────────────────────────────────────────────────
#
# strict 모드에서는 이 SG가 Pod의 아웃바운드를 온전히 통제한다. 노드 SG의 egress_all은
# 적용되지 않으므로, 여기 없는 목적지는 전부 차단된다 — 아래 규칙이 곧 이 Pod가 나갈 수 있는
# 범위 전체다. 특히 DNS를 빠뜨리면 이름 해석부터 실패해 RDS 주소조차 못 찾는다.
#
# egress를 인라인 블록이 아닌 별도 리소스로 관리하는 이유는 리소스 주소 안정성이다 —
# 인라인 규칙은 Terraform이 관리하지 않는 규칙을 매 apply마다 삭제한다
# (docs/terraform-principles.md 참조).
#
# 0.0.0.0/0 egress를 의도적으로 넣지 않는다. strict 모드가 Pod 단위 인터넷 차단을 실제로
# 강제하는지 검증하는 것이 이 구성의 목적 중 하나다(docs/security-groups-for-pods.md 검증 항목).
# 컨테이너 이미지 pull은 kubelet이 노드 ENI로 수행하므로 이 SG와 무관하다.
locals {
  pod_sg_egress_rules = {
    postgresql = {
      description = "RDS PostgreSQL"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
    }
    dns_tcp = {
      description = "CoreDNS lookup (TCP)"
      from_port   = 53
      to_port     = 53
      protocol    = "tcp"
    }
    dns_udp = {
      description = "CoreDNS lookup (UDP)"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "pod_rds_access" {
  for_each = local.pod_sg_egress_rules

  security_group_id = aws_security_group.pod_rds_access.id
  description       = each.value.description
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol

  tags = {
    Name = "${local.cluster_name}-pod-rds-access-${each.key}"
  }
}

# ── 목적지 쪽 SG에 이 SG를 허용시키기 ─────────────────────────────────────────
#
# [strict 모드의 일반 원칙] Pod SG는 이 Pod가 말을 거는 **모든 목적지**에서 출발지 신원이 된다.
# 따라서 egress를 여는 것만으로는 부족하고, 목적지 SG가 이 SG를 인바운드로 받아줘야 한다.
# RDS는 rds root가 처리하고(RDS SG inbound ← 이 SG), DNS는 아래에서 처리한다.
#
# [왜 DNS가 문제인가] CoreDNS는 role=system nodeAffinity로 시스템 노드(t3)에 고정돼 있고,
# SGP Pod는 t 계열 미지원이라 항상 Karpenter 노드에 뜬다. strict 모드에서는 같은 노드 안이든
# 아니든 모든 아웃바운드가 VPC를 경유하므로, DNS 질의가 브랜치 ENI로 나가 시스템 노드에 도착한다.
# 그런데 노드 SG의 53 인바운드는 업스트림 모듈이 만드는 self 규칙(출발지 = 노드 SG)뿐이라
# Pod SG를 달고 온 트래픽이 매칭되지 않는다 — 규칙을 추가하지 않으면 이름 해석이 실패한다.
# SGP를 안 쓰는 Pod는 노드 ENI로 나가 self 규칙에 걸리므로 이 문제가 드러나지 않는다.
resource "aws_vpc_security_group_ingress_rule" "node_dns_from_pod_sg" {
  for_each = toset(["tcp", "udp"])

  security_group_id            = local.node_security_group_id
  description                  = "CoreDNS lookup from SGP-enabled pods (${each.key})"
  referenced_security_group_id = aws_security_group.pod_rds_access.id
  from_port                    = 53
  to_port                      = 53
  ip_protocol                  = each.key

  tags = {
    Name = "${local.cluster_name}-node-dns-from-pod-sg-${each.key}"
  }
}

# ── ingress ───────────────────────────────────────────────────────────────────
#
# 이 SG 자체에는 인바운드 규칙을 두지 않는다. 이 SG를 붙일 워크로드는 나가기만 하고 외부에서
# 들어오는 연결을 받지 않는다.
#
# [제약] 그래서 이 Pod는 pull 방식 스크레이핑 대상이 될 수 없다. Prometheus나 OTel이
# ServiceMonitor로 긁으려 하면 차단되고, 메트릭이 조용히 사라진다. 현재 dev의 OTel은
# DaemonSet push 방식이라 해당 없지만, SGP 대상 워크로드에 pull 수집을 붙이려면 여기에
# 인바운드 규칙을 추가해야 한다.
#
# ALB가 이 Pod를 타깃으로 삼게 되면(target-type: ip) 그때는 ALB SG로부터의 인바운드가
# 필요하다. 그 규칙은 LBC가 자동으로 넣어주는데, 찾으려면 이 SG에
# kubernetes.io/cluster/${local.cluster_name} = owned 태그가 있어야 한다.
# 지금은 ALB 타깃이 아니라 태그를 붙이지 않는다 — 붙이면 LBC가 관여할 이유가 없는 SG에
# 규칙 쓰기 권한을 갖게 된다.
