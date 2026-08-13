# 태그 값 유효성 검사: Organizations 정책의 허용값을 remote state에서 읽어 검증한다.
# 허용값 변경은 global/tag-policy/main.tf만 수정하면 된다.
resource "terraform_data" "validate_tags" {
  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_environments, local.common_tags.environment)
      error_message = "environment 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_environments)}. 현재 값: '${local.common_tags.environment}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_managed_by, local.common_tags.managed_by)
      error_message = "managed_by 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_managed_by)}. 현재 값: '${local.common_tags.managed_by}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_projects, local.common_tags.project)
      error_message = "project 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_projects)}. 현재 값: '${local.common_tags.project}'"
    }
  }
}

################################################################################
# Security Groups for Pods — Pod 전용 보안 그룹
#
# SGP(ENABLE_POD_ENI)를 켜면 SecurityGroupPolicy에 매칭된 Pod가 자기 전용 브랜치 ENI를 받고,
# 그 ENI에 이 SG가 붙는다. 노드 SG를 공유하던 구조에서 벗어나 Pod 단위로 통제된다.
#
# ─────────────────────────────────────────────────────────────────────────────
# [실습 환경 전용 구조 — 실무에서는 이렇게 나누지 않아도 된다]
#
# 이 root를 별도로 둔 유일한 이유는 **SG ID를 teardown 사이클 너머로 고정**하기 위해서다.
# 이 프로젝트는 비용 때문에 클러스터를 반복해서 destroy/재생성하는데, SG가 eks-addons에 있으면
# 그때마다 삭제되고 새 ID를 받는다. 그 ID를 devops-manifest의 SecurityGroupPolicy CR이 참조하므로
# 매번 값을 따라가야 한다(GitOps Bridge annotation 경유). ID가 고정되면 매니페스트가 리터럴로
# 참조할 수 있고 그 브릿지를 없앨 수 있다.
#
# 실무에서는 클러스터를 상시 운영하므로 이 제약이 없다. 그때는 SGP의 단위가 워크로드라는 점을
# 살려 **각 서비스 root가 자기 Pod SG를 소유하고, 자기가 필요한 목적지에 자기 ingress 규칙을
# 등록하는 구조**가 더 자연스럽다(order/network, catalog/network 식). 이 프로젝트는 아직 RDS를
# 쓰는 서비스가 없어 검증용 SG 하나뿐이라 그 분화를 하지 않았을 뿐이다 —
# locals.tf의 pod_security_groups는 키만 추가하면 분화되도록 맵으로 만들어 두었다.
# ─────────────────────────────────────────────────────────────────────────────
#
# [영속성을 지키는 규칙] 이 root는 VPC 외에 아무것도 참조하지 않는다. 클러스터·애드온을
# 참조하는 순간 teardown에 끌려들어가 존재 이유가 사라진다. 노드 SG가 얽히는 규칙(DNS·probe)을
# 여기 두지 않고 eks-addons에 남긴 것도 같은 이유다.
#
# [teardown 제외] .claude/skills/env-teardown/SKILL.md의 삭제 대상에 이 root는 없다.
# SG는 그 자체로 과금되지 않으므로 유지해도 비용이 늘지 않는다.
################################################################################

resource "aws_security_group" "pod" {
  for_each = local.pod_security_groups

  # name이 아니라 name_prefix를 쓴다. SG 이름은 VPC 내에서 유일해야 하는데, description처럼
  # Update API가 없는 속성을 바꾸면 SG가 ForceNew로 재생성된다 — 이때 create_before_destroy는
  # 기존 SG가 살아있는 상태에서 신규를 먼저 만들려 하므로 이름이 고정이면 InvalidGroup.Duplicate로
  # apply가 통째로 실패한다. 참조는 전부 ID 기반이라 이름이 랜덤 접미사를 가져도 무방하고,
  # 사람이 식별하는 값은 Name 태그가 담당한다.
  name_prefix = "${local.cluster_name}-${each.value.name_suffix}-"
  description = each.value.description
  vpc_id      = local.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.cluster_name}-${each.value.name_suffix}"
  }
}

# egress를 인라인 블록이 아닌 별도 리소스로 관리하는 이유는 리소스 주소 안정성이다 —
# 인라인 규칙은 Terraform이 관리하지 않는 규칙을 매 apply마다 삭제한다
# (docs/terraform-principles.md 참조).
resource "aws_vpc_security_group_egress_rule" "pod" {
  for_each = local.pod_sg_egress_rules

  security_group_id = aws_security_group.pod[each.value.sg_key].id
  description       = each.value.description
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol

  tags = {
    Name = "${local.cluster_name}-${local.pod_security_groups[each.value.sg_key].name_suffix}-${split(".", each.key)[1]}"
  }
}

# ── 인바운드를 여기 두지 않는 이유 ────────────────────────────────────────────
#
# 이 SG에 필요한 인바운드는 두 가지인데 둘 다 출발지가 클러스터 소유 SG다:
#   - kubelet probe : 출발지 = 노드 SG
#   - ALB 헬스체크  : 출발지 = LBC가 만든 ALB SG (LBC가 자동 삽입, SG 태그 필요)
# 여기서 노드 SG를 참조하면 이 root가 클러스터 lifecycle에 묶여 teardown 생존이 깨진다.
# probe 규칙은 eks-addons/pod-security-groups.tf가 만든다.
#
# [제약] 그래서 이 Pod는 pull 방식 스크레이핑 대상이 될 수 없다. Prometheus나 OTel이
# ServiceMonitor로 긁으려 하면 차단되고 메트릭이 조용히 사라진다. 현재 dev의 OTel은
# DaemonSet push 방식이라 해당 없다.
