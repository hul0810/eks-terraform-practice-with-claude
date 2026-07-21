output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN. blueprints가 생성한다"
  value       = module.eks_blueprints_addons_gitops.aws_load_balancer_controller.iam_role_arn
}

output "karpenter_role_arn" {
  description = "Karpenter 컨트롤러 IRSA IAM Role ARN. blueprints가 생성한다"
  value       = module.eks_blueprints_addons_gitops.karpenter.iam_role_arn
}

output "karpenter_node_iam_role_name" {
  description = "Karpenter 노드 IAM Role 이름. EC2NodeClass의 role 필드에 사용한다"
  value       = module.eks_blueprints_addons_gitops.karpenter.node_iam_role_name

  precondition {
    # enable_karpenter = true인데 Role 이름이 비어있으면 EC2NodeClass에 빈 값이 주입되어 노드 조인 실패
    condition     = !var.enable_karpenter || module.eks_blueprints_addons_gitops.karpenter.node_iam_role_name != ""
    error_message = "enable_karpenter = true이지만 karpenter_node IAM Role 이름이 비어 있습니다. karpenter_node 설정을 확인하세요."
  }
}

output "external_dns_role_arn" {
  description = "ExternalDNS IRSA IAM Role ARN. blueprints가 생성한다. external_dns_route53_zone_arns가 비면 빈 문자열 반환"
  value       = module.eks_blueprints_addons_gitops.external_dns.iam_role_arn
}

output "external_secrets_role_arn" {
  description = "External Secrets Operator IRSA IAM Role ARN. blueprints가 생성한다. Role 신뢰 정책의 OIDC sub 조건은 system:serviceaccount:external-secrets:external-secrets-sa로 고정된다"
  value       = module.eks_blueprints_addons_gitops.external_secrets.iam_role_arn
}

# GitOps Bridge 메타데이터 번들 — 직접 map을 조립하지 않고 aws-ia/eks-blueprints-addons
# 벤더 모듈이 이미 제공하는 공식 output "gitops_metadata"를 그대로 통과시킨다(모듈 자체
# 주석: "This output is intended to be used with GitOps... We guarantee that this output
# will be maintained any time a new addon is added") — upstream이 addon 추가·변경 시
# 항상 최신으로 유지해주는 output이라 직접 조립하는 것보다 유지보수 보장이 강하다.
# namespace/service_account, Karpenter의 sqs_queue_name/node_instance_profile_name까지
# 포함하며, 키 네이밍은 `aws_load_balancer_controller_iam_role_arn`,
# `karpenter_node_iam_role_name` 등 `{addon}_{field}` 패턴이다 — devops-manifest의
# annotation 키 이름도 이 패턴에 맞춰야 한다. 공식 gitops-bridge-dev/gitops-bridge
# Terraform 모듈도 정확히 이 output을 cluster Secret의 metadata에 그대로 merge하는
# 방식을 쓴다.
output "gitops_bridge_addon_metadata" {
  description = "ArgoCD cluster Secret annotation에 그대로 병합해 넣을 수 있는 addon 메타데이터 map. aws-ia/eks-blueprints-addons 벤더 모듈의 공식 gitops_metadata output을 그대로 노출한다(직접 조립하지 않음 — addon이 추가/변경되면 벤더가 자동으로 갱신)."
  value       = module.eks_blueprints_addons_gitops.gitops_metadata
}
