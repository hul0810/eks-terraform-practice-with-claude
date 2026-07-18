output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN. blueprints가 생성한다"
  # Phase 6-3: Helm release는 ArgoCD로 이관되고 IAM만 Terraform이 유지 —
  # module.eks_blueprints_addons_gitops(main.tf 참고)로 이동
  value = module.eks_blueprints_addons_gitops.aws_load_balancer_controller.iam_role_arn
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
