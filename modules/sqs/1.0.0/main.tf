# terraform-aws-modules/sqs는 큐 하나당 하나의 모듈 인스턴스를 생성하는 구조.
# for_each로 map key를 stable address로 사용하여 큐 추가/삭제 시 무관한 리소스 재생성을 방지한다.
module "queues" {
  source   = "terraform-aws-modules/sqs/aws"
  version  = "~> 5.2.0"
  for_each = var.queues

  name       = each.key
  fifo_queue = each.value.fifo_queue

  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  delay_seconds              = each.value.delay_seconds
  receive_wait_time_seconds  = each.value.receive_wait_time_seconds
  sqs_managed_sse_enabled    = each.value.sqs_managed_sse_enabled

  # DLQ는 옵션으로만 노출한다 — 이번 커스텀 모듈 호출 범위에서는 사용하지 않아도
  # 필요한 서비스가 개별적으로 활성화할 수 있도록 파라미터 자체는 항상 열어 둔다.
  create_dlq = each.value.create_dlq
}
