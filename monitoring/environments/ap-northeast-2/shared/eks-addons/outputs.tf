output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN"
  value       = module.eks_addons.lbc_role_arn
}

output "karpenter_role_arn" {
  description = "Karpenter 컨트롤러 IRSA IAM Role ARN"
  value       = module.eks_addons.karpenter_role_arn
}

output "karpenter_node_iam_role_name" {
  description = "Karpenter 노드 IAM Role 이름. EC2NodeClass의 role 필드에 사용한다"
  value       = module.eks_addons.karpenter_node_iam_role_name
}

output "external_dns_role_arn" {
  description = "ExternalDNS IRSA IAM Role ARN. project/global/ap-northeast-2/external-dns-cross-account-role의 Trust Policy에서 참조한다"
  value       = module.eks_addons.external_dns_role_arn
}
