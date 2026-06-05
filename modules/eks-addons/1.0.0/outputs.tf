output "ebs_csi_role_arn" {
  description = "EBS CSI Driver Pod Identity IAM Role ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "external_dns_role_arn" {
  description = "External DNS Pod Identity IAM Role ARN. enable_external_dns=false이면 null"
  # for_each 맵에서 단일 값을 꺼낸다. enable_external_dns=false이면 빈 맵 → null 반환
  value = var.enable_external_dns ? aws_iam_role.external_dns[0].arn : null
}

output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN. eks-blueprints-addons 모듈이 생성한다"
  value       = module.eks_blueprints_addons.aws_load_balancer_controller.iam_role_arn
}
