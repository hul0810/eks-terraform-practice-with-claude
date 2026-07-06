output "queue_urls" {
  description = "큐 이름 → URL 맵 (애플리케이션 SQS_QUEUE_URL 환경변수 주입 시 사용)"
  value       = { for k, v in module.queues : k => v.queue_url }
}

output "queue_arns" {
  description = "큐 이름 → ARN 맵 (IAM 정책 Resource 지정 시 사용)"
  value       = { for k, v in module.queues : k => v.queue_arn }
}
