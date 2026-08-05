################################################################################
# order 서비스 SQS 접근 — EKS Pod Identity
#
# 신뢰 정책은 서비스 principal pods.eks.amazonaws.com 하나만 보고, "어느 네임스페이스의 어느
# SA가 이 Role을 쓸 수 있는가"는 IAM이 아니라 EKS 쪽 association 리소스가 결정한다. 그래서
# Role 신뢰 정책에 클러스터 OIDC 정보가 들어가지 않고, K8s SA에 annotation을 붙일 필요도 없다
# — devops-manifest를 건드리지 않고 Terraform만으로 권한 연결이 끝난다.
#
# 자격증명은 노드의 eks-pod-identity-agent가 HTTP 엔드포인트로 제공하며, SDK의 container
# credential provider가 이를 집어간다. 에이전트 애드온은 modules/eks/1.0.0이 이미 설치한다.
#
# 프로젝트 기본 전략(docs/addon-strategy.md → IAM 전략): Pod Identity를 쓸 수 있으면 항상 우선.
################################################################################

resource "aws_iam_role" "order_sqs_pod_identity" {
  name = local.pod_identity_role_name

  # IAM Role의 description은 ASCII/Latin-1(U+0020~U+007E, U+00A1~U+00FF)만 허용해서 한글을
  # 넣으면 CreateRole이 ValidationError로 거부한다. aws_iam_policy의 description에는 이 제약이
  # 없어 그쪽은 한글을 그대로 쓴다.
  description = "SQS publish access for order Pod (${local.k8s_namespace}/${local.k8s_service_account}) via EKS Pod Identity"

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
        # Pod Identity는 세션에 클러스터/네임스페이스/SA 태그를 붙여서 신원을 넘긴다.
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          # confused deputy 방지. 이 조건이 없으면 같은 계정의 다른 EKS 클러스터에 이 Role을
          # 가리키는 association을 만드는 것만으로 SQS 발행 권한을 얻을 수 있다.
          # Role을 여러 클러스터에서 재사용하려면 SourceArn을 그만큼 넓혀야 하지만, 이 Role은
          # 애초에 이름부터 클러스터 전용이라 잃는 게 없다.
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
  # association의 role_arn이 갱신된다 — 그 사이 association이 없는 Role을 가리켜 Pod의
  # 자격증명 갱신이 실패한다. modules/eks/1.0.0의 vpc_cni·ebs_csi Role과 동일한 방어다.
  lifecycle {
    create_before_destroy = true
  }
}

# association이 존재해야 비로소 Pod이 이 Role의 자격증명을 받는다. Role만 만들고 이걸 빠뜨리면
# Pod에 자격증명 env가 아예 주입되지 않는다(노드 IMDS는 hop limit 1로 막혀 있어 폴백도 없다).
#
# 자격증명 env는 admission 시점에 주입되므로, 이 리소스를 새로 만들거나 role_arn을 바꾼 뒤에는
# 대상 Pod을 재생성해야 반영된다.
resource "aws_eks_pod_identity_association" "order_sqs" {
  cluster_name    = local.cluster_name
  namespace       = local.k8s_namespace
  service_account = local.k8s_service_account
  role_arn        = aws_iam_role.order_sqs_pod_identity.arn
}

# IRSA 실습 코드를 걷어내면서 방식 전환용 for_each 토글이 사라져 리소스 주소가 바뀌었다.
# 이 블록이 없으면 association이 destroy/create된다.
moved {
  from = aws_eks_pod_identity_association.order_sqs["order-dev"]
  to   = aws_eks_pod_identity_association.order_sqs
}
