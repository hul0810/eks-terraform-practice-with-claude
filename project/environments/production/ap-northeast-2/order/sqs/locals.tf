locals {
  environment = "production"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. production은 environment_short를 빈 문자열로 두어 구분자까지 완전히 제거한다.
  environment_short = ""
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # 큐 이름 패턴: {project}-{service}-events{name_suffix}
  # production: name_suffix="" → "eks-practice-order-events"
  # 이 root module은 order 서비스가 발행하는 order.created 이벤트 큐 전용이다.
  # 다른 서비스의 SQS는 project/environments/production/ap-northeast-2/{service}/sqs/ 에
  # 별도 root module로 관리한다.
  # outputs.tf에서 동일 문자열을 다시 조립하면 이 패턴이 바뀔 때 두 곳을 함께 고쳐야 하므로
  # 단일 소스로 추출한다.
  queue_name = "${local.project}-order-events${local.name_suffix}"

  queues = {
    (local.queue_name) = {
      # order.created 이벤트는 순서 보장·중복 제거가 필요하지 않으므로 Standard 큐로 충분하다
      # (모듈 기본값 fifo_queue = false 유지 — 여기 명시하지 않음).
      # DLQ는 이번 요청 범위에서 제외 — 사용자가 메인 큐만 우선 생성하기로 결정함
      # (모듈 기본값 create_dlq = false 유지).
      # visibility_timeout_seconds, message_retention_seconds, delay_seconds,
      # receive_wait_time_seconds, sqs_managed_sse_enabled도 전부 모듈 기본값 사용.
    }
  }
}
