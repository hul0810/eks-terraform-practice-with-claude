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

# Pod SG ID는 이 root가 아니라 pods-sg가 소유하므로 여기서 output하지 않는다.
# rds root는 pods-sg를 직접 참조한다.
