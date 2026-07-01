output "role_arn" {
  description = "Route53 크로스 계정 위임 IAM Role ARN. monitoring eks-addons의 external_dns_assume_role_arn에 주입한다"
  value       = aws_iam_role.route53_delegation.arn
}
