################################################################################
# Notifications(Slack) 전용 IRSA — GitHub App Private Key와 분리된 신뢰 경계
#
# [왜 별도 신뢰 경계를 만드는가]
# 기존에는 argo-rollouts/argocd 네임스페이스의 Slack Bot Token ExternalSecret이
# main.tf의 공용 ClusterSecretStore(aws-parameterstore)를 GitHub App Private Key(조직 전체
# 저장소 쓰기 권한)/Image Updater git-creds와 함께 썼다. 이 Store 뒤의 IAM Role
# (external-secrets-sa IRSA)은 두 경로를 모두 읽을 수 있어서, argo-rollouts 네임스페이스에
# 생성되는 ExternalSecret이 실수로(또는 악의적으로) GitHub App Private Key 경로를 remoteRef로
# 지정하면 그대로 읽어갈 수 있는 상태였다 — 보안 리뷰에서 지적된 권한 과다 문제.
# Slack Bot Token 전용으로 완전히 분리된 신뢰 경계(전용 IAM Role + 전용 SA)를 만들어
# 이 Role의 SSM 읽기 권한을 Slack Bot Token 경로 하나로 제한한다.
# GitHub App/Image Updater 쪽(main.tf의 aws_parameterstore_secret_store, external-secrets-sa)은
# 이미 검증된 라이브 코드라 이번 변경 범위에서 제외한다.
#
# [왜 네임스페이스 스코프 SecretStore가 아니라 ClusterSecretStore인가]
# argo-rollouts 네임스페이스는 이 root도 module.eks_addons도 만들지 않는다 — 오직
# ArgoCD의 argo-rollouts Application sync가 만든다. Terraform이 그 네임스페이스 안에
# SA를 직접 만들려 하면, ArgoCD의 비동기 sync 완료 여부와 무관하게 apply가 실행되므로
# 네임스페이스가 아직 없을 때 실패할 수 있다. ClusterSecretStore는 SA를 하나만 참조하고
# 그 SA를 가진 네임스페이스와 무관하게 어느 네임스페이스의 ExternalSecret이든 참조할 수
# 있으므로, SA를 항상 Terraform이 직접 만드는 argocd 네임스페이스 하나에만 두면
# argo-rollouts 쪽 네임스페이스 생성 타이밍에 대한 의존성 자체가 사라진다. Slack Bot
# Token은 GitHub App Private Key보다 민감도가 낮아 "어느 네임스페이스든 참조 가능"이라는
# 도달 범위 확대는 감수할 만한 트레이드오프로 판단했다 — IAM Role의 SSM 읽기 권한은
# 여전히 Slack Bot Token 경로 하나로 제한되어 격리 의도 자체는 유지된다.
#
# ClusterSecretStore 리소스 자체와 그걸 참조하는 ExternalSecret 2개는 GitOps Bridge로
# eks-practice-devops-manifest가 관리한다(요청 완료 대기 — 이 저장소 밖 변경).
################################################################################

resource "aws_iam_role" "notifications_slack" {
  name = "${local.cluster_name}-notifications-slack-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "NotificationsSlackIrsa"
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:argocd:notifications-eso-sa"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# SSM SecureString은 KMS 복호화 권한도 별도로 필요하다 (data.aws_kms_alias.ssm_default는
# main.tf의 공용 Store와 동일하게 SSM 기본 키를 가리킨다 — data.tf 참조).
resource "aws_iam_role_policy" "notifications_slack_ssm_read" {
  name = "ssm-slack-bot-token-read"
  role = aws_iam_role.notifications_slack.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SsmSlackBotTokenRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/notifications/slack-bot-token"
      },
      {
        Sid      = "KmsDecryptSsmDefault"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.aws_kms_alias.ssm_default.target_key_arn
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "notifications_eso_argocd" {
  metadata {
    name      = "notifications-eso-sa"
    namespace = "argocd"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.notifications_slack.arn
    }
  }

  # argocd 네임스페이스는 이 root에서 별도로 생성하지 않는다 — ArgoCD는 부트스트랩 예외로
  # 계속 Terraform이 Helm까지 관리하므로(module.eks_addons의 gitops_bridge_bootstrap 인스턴스),
  # 그 Helm release가 자체적으로 namespace를 생성한다. 이 root가 직접 통제하지 않는
  # argo-rollouts 네임스페이스와 달리, 이 경로는 ArgoCD 비동기 sync 완료 시점에 의존하지
  # 않는다 — 이 SA가 유일하게 안전한 위치인 이유이기도 하다(ClusterSecretStore가 이
  # SA 하나만 참조하고, argo-rollouts 네임스페이스의 ExternalSecret도 네임스페이스 경계
  # 없이 이 Store를 그대로 참조한다).
  depends_on = [module.eks_addons]
}

# ClusterSecretStore(aws-parameterstore-notifications, argocd 네임스페이스 SA 참조 하나)와
# 그걸 참조하는 ExternalSecret 2개(argocd, argo-rollouts 네임스페이스)는 GitOps Bridge로
# eks-practice-devops-manifest 저장소의 ArgoCD Application이 관리한다. IAM Role +
# ServiceAccount(위)는 계속 Terraform이 관리한다.
