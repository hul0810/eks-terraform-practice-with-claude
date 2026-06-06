output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN"
  value       = module.eks_addons.lbc_role_arn
}

output "karpenter_role_arn" {
  description = "Karpenter 컨트롤러 IRSA IAM Role ARN"
  value       = module.eks_addons.karpenter_role_arn
}
