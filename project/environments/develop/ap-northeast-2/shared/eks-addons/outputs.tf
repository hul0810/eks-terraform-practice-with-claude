output "ebs_csi_role_arn" {
  description = "EBS CSI Driver Pod Identity IAM Role ARN"
  value       = module.eks_addons.ebs_csi_role_arn
}

output "external_dns_role_arn" {
  description = "External DNS Pod Identity IAM Role ARN (enable_external_dns=false이면 null)"
  value       = module.eks_addons.external_dns_role_arn
}

output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IRSA IAM Role ARN"
  value       = module.eks_addons.lbc_role_arn
}
