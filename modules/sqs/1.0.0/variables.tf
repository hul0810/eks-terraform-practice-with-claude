variable "queues" {
  description = "생성할 SQS 큐 설정 맵. key는 완전한 큐 이름({project}-{service}-events{environment} 패턴 권장, FIFO 큐는 반드시 \".fifo\"로 끝나야 함)"
  type = map(object({
    fifo_queue                 = optional(bool, false)
    visibility_timeout_seconds = optional(number, null)
    message_retention_seconds  = optional(number, null)
    delay_seconds              = optional(number, null)
    receive_wait_time_seconds  = optional(number, null)
    sqs_managed_sse_enabled    = optional(bool, true)
    create_dlq                 = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.queues :
      v.fifo_queue == endswith(k, ".fifo")
    ])
    error_message = "FIFO 큐(fifo_queue = true)는 이름이 반드시 \".fifo\"로 끝나야 하고, Standard 큐는 \".fifo\"로 끝나면 안 됩니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.queues :
      v.visibility_timeout_seconds == null || (v.visibility_timeout_seconds >= 0 && v.visibility_timeout_seconds <= 43200)
    ])
    error_message = "visibility_timeout_seconds는 0~43200(12시간) 사이여야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.queues :
      v.message_retention_seconds == null || (v.message_retention_seconds >= 60 && v.message_retention_seconds <= 1209600)
    ])
    error_message = "message_retention_seconds는 60(1분)~1209600(14일) 사이여야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.queues :
      v.delay_seconds == null || (v.delay_seconds >= 0 && v.delay_seconds <= 900)
    ])
    error_message = "delay_seconds는 0~900(15분) 사이여야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.queues :
      v.receive_wait_time_seconds == null || (v.receive_wait_time_seconds >= 0 && v.receive_wait_time_seconds <= 20)
    ])
    error_message = "receive_wait_time_seconds는 0~20 사이여야 합니다."
  }
}
