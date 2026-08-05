locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # 큐 이름 패턴: {project}-{service}-events{name_suffix}
  # 이 root module은 order 서비스가 발행하는 order.created 이벤트 큐 전용이다.
  # 다른 서비스의 SQS는 project/environments/develop/ap-northeast-2/{service}/sqs/ 에
  # 별도 root module로 관리한다.
  # outputs.tf에서 동일 문자열을 다시 조립하면 이 패턴이 바뀔 때 두 곳을 함께 고쳐야 하므로
  # 단일 소스로 추출한다.
  queue_name = "${local.project}-order-events${local.name_suffix}"

  # ── order Pod → SQS 권한 부여 ────────────────────────────────────────────────
  # 큐를 소유한 이 root module이 IAM Role도 함께 관리한다. 큐 ARN이 여기 있어
  # shared/eks-addons로 옮기면 remote_state 왕복이 한 번 더 생긴다.

  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name

  # order Pod이 사용하는 ServiceAccount 좌표. eks-practice-devops-manifest 저장소의
  # ApplicationSet(argocd/applicationsets/workload/dev/order.yaml)이 결정하는 값이라
  # Terraform이 조회할 수 없다 — release name "order-dev"가 chart name "order"를 포함해
  # common.names.fullname이 "order-dev"로 렌더링되고, destination.namespace가 "eks-practice-dev"다.
  # 저쪽 releaseName/namespace를 바꾸면 이 두 값도 함께 고쳐야 한다.
  k8s_namespace       = "eks-practice-dev"
  k8s_service_account = "order-dev"

  pod_identity_role_name = "${local.cluster_name}-order-sqs-pod-id"

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
