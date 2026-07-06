<!-- BEGIN_TF_DOCS -->
<!-- 이 파일은 terraform-docs가 자동 생성합니다. 직접 수정하지 마세요. -->
<!-- 설계 결정과 WHY는 같은 디렉토리의 CLAUDE.md를 참조하세요. -->

## Requirements

No requirements.

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_queues"></a> [queues](#module\_queues) | terraform-aws-modules/sqs/aws | ~> 5.2.0 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_queues"></a> [queues](#input\_queues) | 생성할 SQS 큐 설정 맵. key는 완전한 큐 이름({project}-{service}-events{environment} 패턴 권장, FIFO 큐는 반드시 ".fifo"로 끝나야 함) | <pre>map(object({<br/>    fifo_queue                 = optional(bool, false)<br/>    visibility_timeout_seconds = optional(number, null)<br/>    message_retention_seconds  = optional(number, null)<br/>    delay_seconds              = optional(number, null)<br/>    receive_wait_time_seconds  = optional(number, null)<br/>    sqs_managed_sse_enabled    = optional(bool, true)<br/>    create_dlq                 = optional(bool, false)<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_queue_arns"></a> [queue\_arns](#output\_queue\_arns) | 큐 이름 → ARN 맵 (IAM 정책 Resource 지정 시 사용) |
| <a name="output_queue_urls"></a> [queue\_urls](#output\_queue\_urls) | 큐 이름 → URL 맵 (애플리케이션 SQS\_QUEUE\_URL 환경변수 주입 시 사용) |
<!-- END_TF_DOCS -->