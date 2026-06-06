output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN. blueprints가 생성한다"
  value       = module.eks_blueprints_addons.aws_load_balancer_controller.iam_role_arn
}

output "karpenter_role_arn" {
  description = "Karpenter 컨트롤러 IRSA IAM Role ARN. blueprints가 생성한다"
  value       = module.eks_blueprints_addons.karpenter.iam_role_arn
}
