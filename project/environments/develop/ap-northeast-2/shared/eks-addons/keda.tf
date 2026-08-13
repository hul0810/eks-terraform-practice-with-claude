################################################################################
# KEDA — AWS 스케일러 조회용 신원 (EKS Pod Identity)
#
# KEDA가 큐 깊이·메트릭을 읽어 워크로드를 스케일하려면 AWS 조회 권한이 필요하다. 이때
# 스케일 대상 워크로드의 신원을 빌리지 않고 KEDA 오퍼레이터 자신의 신원을 쓴다 — 두 가지
# 이유가 있다.
#
#  1. KEDA의 identityOwner: workload 방식은 대상 SA의 eks.amazonaws.com/role-arn annotation을
#     읽어 그 Role을 assume하는 IRSA 전제 구조다. 이 클러스터는 EKS Pod Identity를 쓰므로
#     SA에 annotation이 없어 성립하지 않는다.
#  2. 권한 집합이 애초에 다르다. 컨슈머는 ReceiveMessage/DeleteMessage가 필요하고 KEDA는
#     GetQueueAttributes가 필요하다 — 한쪽이 다른 쪽 권한을 빌려 쓸 수 있는 관계가 아니다.
#
# [Pod Identity로 동작하는 근거]
# KEDA는 자격증명을 AWS SDK 기본 credential chain으로 해석한다(kedacore/keda의
# pkg/scalers/aws/aws_common.go — config.LoadDefaultConfig). Pod Identity가 파드에 주입하는
# AWS_CONTAINER_CREDENTIALS_FULL_URI가 그 체인에 포함되므로, TriggerAuthentication에
# podIdentity.provider: aws 만 지정하고 roleArn을 비워두면 이 Role이 그대로 쓰인다.
# roleArn을 지정하면 이 신원 위에서 한 번 더 AssumeRole하는 체인이 되므로 지정하지 않는다.
# (KEDA 문서의 "AWS EKS Pod Identity Webhook"(provider: aws-eks)은 이름과 달리 annotation
#  기반 IRSA를 가리키는 레거시 항목이고 v3에서 제거 예정이라 쓰지 않는다.)
#
# [배치 위치] order/sqs가 아니라 이 root가 소유한다. KEDA는 order 전용이 아니라 클러스터
# 공용 애드온이라 앞으로 여러 워크로드의 큐·메트릭을 보게 된다 — 큐를 소유한 root마다
# 신원이 갈라지면 association이 SA 하나에 여러 개 붙을 수 없어 애초에 성립하지 않는다.
################################################################################

resource "aws_iam_role" "keda" {
  name = "${local.cluster_name}-keda-pod-id"

  # IAM Role의 description은 ASCII/Latin-1만 허용해서 한글을 넣으면 CreateRole이
  # ValidationError로 거부한다(aws_iam_policy에는 이 제약이 없다).
  description = "AWS scaler read access for KEDA operator on ${local.cluster_name} via EKS Pod Identity"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EksPodIdentityAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        # sts:TagSession이 없으면 association이 붙어도 자격증명 발급이 실패한다 —
        # Pod Identity는 세션에 클러스터/네임스페이스/SA 태그를 실어 신원을 넘긴다.
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          # confused deputy 방지. 이 조건이 없으면 같은 계정의 다른 EKS 클러스터에서 이 Role을
          # 가리키는 association을 만드는 것만으로 조회 권한을 얻을 수 있다.
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "aws:SourceArn" = data.aws_eks_cluster.this.arn
          }
        }
      }
    ]
  })

  # name 변경은 ForceNew라 기본 destroy→create 순서로는 구 Role이 사라진 뒤에야 아래
  # association의 role_arn이 갱신된다 — 그 사이 association이 없는 Role을 가리켜 KEDA의
  # 자격증명 갱신이 실패한다. modules/eks/1.0.0의 vpc_cni·ebs_csi Role과 동일한 방어다.
  lifecycle {
    create_before_destroy = true
  }
}

# ── 스케일러 조회 권한 ────────────────────────────────────────────────────────
#
# KEDA가 지원하는 AWS 스케일러 중 이 프로젝트에 실제 대상 리소스가 있는 것만 부여한다.
# 대상이 없는 서비스(DynamoDB/Kinesis/MSK)까지 미리 열어두면 "이 권한이 왜 있는가"를
# 실제 사용처로 설명할 수 없는 권한이 남는다 — 필요해지는 시점에 statement를 추가한다.
#
# 추가 시 필요한 액션(2026-08-05 기준 KEDA 공식 문서 확인분):
#   - AWS CloudWatch      : cloudwatch:GetMetricData                (아래 이미 포함)
#   - AWS Kinesis Stream  : kinesis:DescribeStreamSummary
#   - AWS DynamoDB / Streams : KEDA 문서가 액션을 명시하지 않는다 — 도입 시 실측 필요
resource "aws_iam_policy" "keda_scalers" {
  name        = "${local.cluster_name}-keda-scalers"
  description = "KEDA 오퍼레이터가 스케일 판단에 쓰는 AWS 조회 권한 (읽기 전용)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 큐 ARN을 개별 나열하지 않고 프로젝트 워크로드 큐 네이밍으로 묶는다.
        # 개별 나열하면 큐가 늘 때마다 이 정책을 고쳐야 하고, 각 큐를 소유한 root의
        # remote_state를 여기서 참조해야 해서 플랫폼 애드온이 워크로드 root에 역의존한다.
        # 액션이 읽기 전용 메타데이터 조회뿐이라 범위를 넓혀도 얻을 수 있는 것이
        # "큐에 메시지가 몇 개인가"로 한정된다.
        #
        # 패턴이 워크로드 큐(eks-practice-<서비스>-events-dev)만 매칭하고 인프라 큐
        # (eks-practice-dev-karpenter — 접미사 위치가 다르다)는 매칭하지 않는다.
        Sid    = "KedaReadQueueDepth"
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          # ScaledObject가 큐를 URL이 아니라 이름으로 지정할 때 필요하다.
          "sqs:GetQueueUrl",
        ]
        Resource = "arn:aws:sqs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:${local.project}-*${local.name_suffix}"
      },
      {
        # CloudWatch 메트릭 액션은 리소스 수준 권한을 지원하지 않는다 — AWS 문서가
        # "you specify a wildcard character (*) as the resource value"로 명시한다.
        # (Amazon CloudWatch permissions reference)
        Sid      = "KedaReadCloudWatchMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "keda_scalers" {
  role       = aws_iam_role.keda.name
  policy_arn = aws_iam_policy.keda_scalers.arn

  # Role이 create_before_destroy로 교체되는 동안 attachment가 먼저 사라지면 신규 Role에
  # 정책이 붙지 않은 구간이 생긴다 — Role과 같은 lifecycle을 맞춘다.
  lifecycle {
    create_before_destroy = true
  }
}

# association이 있어야 비로소 KEDA 파드에 자격증명 env가 주입된다. Role만 만들고 이걸
# 빠뜨리면 노드 IMDS가 hop limit 1로 막혀 있어 폴백도 없이 NoCredentials로 실패한다.
# 자격증명 env는 admission 시점에 주입되므로 이 리소스를 만든 뒤 keda-operator 파드를
# 재생성해야 반영된다.
resource "aws_eks_pod_identity_association" "keda" {
  cluster_name = local.cluster_name

  # KEDA 차트(charts/eks-addons/keda) 기본값. devops-manifest에서 이 값을 바꾸면 여기도
  # 함께 고쳐야 하며, 불일치해도 apply는 성공하고 런타임에서만 드러난다.
  namespace       = "keda"
  service_account = "keda-operator"

  role_arn = aws_iam_role.keda.arn
}
