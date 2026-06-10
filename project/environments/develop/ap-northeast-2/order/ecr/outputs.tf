output "repository_urls" {
  description = "ECR 리포지토리 URL 맵 (docker push/pull 명령에 사용)"
  value       = module.ecr.repository_urls
}

output "repository_arns" {
  description = "ECR 리포지토리 ARN 맵 (IAM 정책 작성 시 사용)"
  value       = module.ecr.repository_arns
}
