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

output "pod_rds_access_security_group_id" {
  description = "SGP(Security Groups for Pods)로 Pod에 부착하는 RDS 접근용 SG ID. rds root가 RDS SG의 inbound source로 참조하고, SecurityGroupPolicy CR에는 GitOps Bridge payload를 통해 전달된다"
  value       = aws_security_group.pod_rds_access.id
}
