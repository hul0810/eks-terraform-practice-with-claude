output "queue_url" {
  description = "order.created 이벤트 큐 URL — 발행/구독 애플리케이션의 SQS_QUEUE_URL 환경변수에 주입"
  value       = module.sqs.queue_urls[local.queue_name]
}

output "queue_arn" {
  description = "order.created 이벤트 큐 ARN — IAM 정책 Resource 지정 시 사용"
  value       = module.sqs.queue_arns[local.queue_name]
}
