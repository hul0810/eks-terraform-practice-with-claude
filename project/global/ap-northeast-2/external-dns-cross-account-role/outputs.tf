output "role_arn" {
  description = "ExternalDNS 크로스 계정 IAM Role ARN. monitoring eks-addons의 external_dns_assume_role_arn에 주입한다"
  value       = aws_iam_role.external_dns_cross_account_role.arn
}
