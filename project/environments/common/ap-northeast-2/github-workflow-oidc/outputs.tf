output "role_arns" {
  description = "서비스별 GitHub Actions OIDC Role ARN. 앱 레포 GitHub Secrets(AWS_ROLE_ARN_GATEWAY/CATALOG/ORDER)에 등록한다"
  value       = { for k, v in aws_iam_role.github_actions : k => v.arn }
}
