output "queue_url" {
  description = "order.created 이벤트 큐 URL — 발행/구독 애플리케이션의 SQS_QUEUE_URL 환경변수에 주입"
  value       = module.sqs.queue_urls[local.queue_name]
}

output "queue_arn" {
  description = "order.created 이벤트 큐 ARN — IAM 정책 Resource 지정 시 사용"
  value       = module.sqs.queue_arns[local.queue_name]
}

output "order_sqs_pod_identity_role_arn" {
  description = "order Pod에 SQS 발행 권한을 주는 IAM Role ARN. Pod Identity association이 연결하므로 K8s 매니페스트에 주입할 필요는 없다"
  value       = aws_iam_role.order_sqs_pod_identity.arn
}
