locals {
  environment = "develop"
  project     = "eks-practice"

  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id

  # SG 이름 접두사용. 이 root는 클러스터를 참조하지 않으므로 remote_state로 읽지 않고
  # eks/locals.tf와 동일한 규칙으로 조립한다 — 클러스터가 없는 상태에서도 apply되어야 한다.
  cluster_name = "${local.project}${local.name_suffix}"

  # ── SGP Pod SG 정의 ─────────────────────────────────────────────────────────
  #
  # 현재는 RDS 접근용 하나뿐이다. 워크로드가 늘면 여기에 키를 추가해 SG를 분화한다 —
  # SGP의 단위는 워크로드이므로 공용 SG 하나를 여럿이 공유하면 목적지에서 서로 구분되지 않아
  # 도입 목적이 깎인다(docs/security-groups-for-pods.md "SG는 워크로드별로" 참조).
  #
  # [egress] strict 모드에서 이 목록이 곧 그 Pod가 나갈 수 있는 범위 전체다.
  #   - 0.0.0.0/0을 의도적으로 넣지 않는다(Pod 단위 인터넷 차단 검증 목적)
  #   - DNS를 빠뜨리면 이름 해석부터 실패해 목적지 주소조차 못 찾는다
  #   - 컨테이너 이미지 pull은 kubelet이 노드 ENI로 수행하므로 이 SG와 무관하다
  #
  # [probe_ports] kubelet이 이 Pod에 붙을 포트. 규칙 자체는 이 root가 만들지 않는다 —
  #   출발지가 노드 SG(클러스터 소유)라 여기서 참조하면 이 root가 클러스터 lifecycle에
  #   묶여버리기 때문이다. 값만 output으로 넘기고 규칙은 eks-addons가 만든다.
  #   strict 모드에서 kubelet -> Pod 연결은 브랜치 ENI를 거쳐 실제 네트워크를 타므로 SG 평가를
  #   받는다 — 열지 않으면 liveness/readiness probe가 i/o timeout으로 전부 실패한다
  #   (2026-08-12 실측). DISABLE_TCP_EARLY_DEMUX는 커널 계층에서 경로를 열어줄 뿐이라
  #   이 규칙을 대체하지 못한다.
  pod_security_groups = {
    rds_access = {
      name_suffix = "pod-rds-access"
      description = "Pod-level security group granting RDS access via EKS Security Groups for Pods"

      egress_rules = {
        postgresql = { description = "RDS PostgreSQL", from_port = 5432, to_port = 5432, protocol = "tcp" }
        dns_tcp    = { description = "CoreDNS lookup (TCP)", from_port = 53, to_port = 53, protocol = "tcp" }
        dns_udp    = { description = "CoreDNS lookup (UDP)", from_port = 53, to_port = 53, protocol = "udp" }
      }

      # 검증용 워크로드(devops-manifest의 sgp-test)가 쓰는 포트.
      # 실제 서비스에 적용할 때는 그 서비스의 probe 포트로 바꾼다.
      probe_ports = [8080]
    }
  }

  # for_each용 평탄화 — SG × egress 규칙
  pod_sg_egress_rules = merge([
    for sg_key, sg in local.pod_security_groups : {
      for rule_key, rule in sg.egress_rules :
      "${sg_key}.${rule_key}" => merge(rule, { sg_key = sg_key })
    }
  ]...)
}
