################################################################################
# GitOps Bridge Registry — self-service 등록 (spoke 쪽)
#
# Hub(monitoring)가 이 클러스터를 spoke로 등록하려면 엔드포인트/CA/spoke Role ARN/addon
# IAM 메타데이터를 알아야 한다. 예전에는 이 값들을 Hub의
# monitoring/.../eks-addons/gitops-bridge-spokes.tf가 손으로 유지하는 map에 넣거나
# role_name 네이밍 패턴으로 추측 재조합했다 — 이 root(자기 자신)가 이미 정확히 아는 값을
# Hub가 다시 추측하는 fragile한 구조였다.
#
# 이 파일은 그 값을 이 클러스터가 직접 SSM Parameter Store(Standard tier, String)에 발행한다.
# Hub는 그 경로를 discovery만 한다(monitoring/.../eks-addons/gitops-bridge-registry.tf) —
# 이 root가 dev/prod 어느 쪽이든, 심지어 신규 spoke가 추가되어도 Hub 코드는 바뀌지 않는다.
#
# 값이 아니라 payload 자체는 locals.tf(gitops_bridge_registry_payload)에서 조립한다 —
# 프로젝트 컨벤션(환경별 설정값은 locals.tf에 집중 관리)에 따른다.
################################################################################

resource "aws_ssm_parameter" "gitops_bridge_registry" {
  provider = aws.gitops_bridge_registry

  # 경로 세그먼트의 계정 ID는 이 root 자신의 계정(workload, 기본 provider)이어야 한다 —
  # Hub(monitoring/.../eks-addons/gitops-bridge-registry.tf)가 신뢰 계정마다 만드는
  # writer Role의 정책이 이 계정 ID를 리터럴로 고정해 스코프하므로, 이 경로가 그 값과
  # 일치하지 않으면 AccessDenied가 난다.
  name = "/eks-practice/gitops-bridge/spokes/${data.aws_caller_identity.current.account_id}/${local.cluster_name}"

  description = "GitOps Bridge Hub(monitoring)이 discovery하는 self-service spoke 등록 정보"
  type        = "String"
  tier        = "Standard"
  value       = jsonencode(local.gitops_bridge_registry_payload)

  tags = local.common_tags
}
