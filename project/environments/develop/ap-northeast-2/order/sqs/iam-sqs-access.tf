################################################################################
# order 서비스 SQS 접근 권한
#
# Role 인라인 정책이 아니라 독립된 관리형 정책으로 둔다. "order 이벤트를 발행할 수 있다"는
# 권한 단위가 Role보다 오래 살기 때문이다 — 나중에 다른 신원(예: 배치 잡, 다른 클러스터의
# Role)이 같은 큐에 발행해야 하면 이 정책을 그대로 붙이면 된다.
################################################################################

resource "aws_iam_policy" "order_sqs_producer" {
  name        = "${local.cluster_name}-order-sqs-producer"
  description = "order 서비스가 ${local.queue_name} 큐에 order.created 이벤트를 발행하기 위한 최소 권한"

  # 발행자(producer) 권한만 부여한다. ReceiveMessage/DeleteMessage는 이 서비스가 자기 큐를
  # 소비하지 않으므로 제외 — 소비자가 생기면 그 서비스의 root module에서 별도 Role을 만든다.
  #
  # GetQueueUrl/GetQueueAttributes를 함께 주는 이유: AWS SDK가 큐 이름만으로 초기화될 때
  # GetQueueUrl을 호출하고, 일부 SDK 래퍼가 FIFO 여부·visibility timeout 확인을 위해
  # GetQueueAttributes를 호출한다. 둘 다 Read 액세스 레벨이라 발행자 권한 범위를 넓히지 않는다.
  # 액션별 액세스 레벨 근거: https://docs.aws.amazon.com/service-authorization/latest/reference/list_sqs.html
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OrderEventsProduce"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
        ]
        Resource = module.sqs.queue_arns[local.queue_name]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "order_sqs_pod_identity" {
  role       = aws_iam_role.order_sqs_pod_identity.name
  policy_arn = aws_iam_policy.order_sqs_producer.arn

  # Role이 create_before_destroy로 교체되는 동안 attachment가 먼저 사라지면 신규 Role에
  # 정책이 붙지 않은 구간이 생긴다 — Role과 같은 lifecycle을 맞춘다.
  lifecycle {
    create_before_destroy = true
  }
}
