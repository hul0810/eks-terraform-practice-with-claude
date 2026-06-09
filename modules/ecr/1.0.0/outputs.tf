output "repository_urls" {
  description = "리포지토리 이름 → URL 맵 (docker push/pull 시 사용)"
  value       = { for k, v in module.repositories : k => v.repository_url }
}

output "repository_arns" {
  description = "리포지토리 이름 → ARN 맵 (IAM 정책 Resource 지정 시 사용)"
  value       = { for k, v in module.repositories : k => v.repository_arn }
}

output "registry_id" {
  description = "ECR 레지스트리 ID (AWS 계정 ID와 동일)"
  # 모든 리포지토리의 registry_id는 동일(동일 계정)하므로 임의 하나에서 추출한다
  value = length(module.repositories) > 0 ? one(values(module.repositories)).repository_registry_id : null
}
