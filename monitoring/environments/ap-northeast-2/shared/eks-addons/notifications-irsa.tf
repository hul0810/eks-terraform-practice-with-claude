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
# ESO 공식 문서·커뮤니티 권고("기본값은 네임스페이스 스코프 SecretStore, 진짜 클러스터
# 공유일 때만 ClusterSecretStore")를 따라 Slack Bot Token 전용으로 완전히 분리된 신뢰
# 경계(전용 IAM Role + 전용 SA + 네임스페이스 스코프 SecretStore)를 만든다.
# GitHub App/Image Updater 쪽(main.tf의 aws_parameterstore_secret_store, external-secrets-sa)은
# 이미 검증된 라이브 코드라 이번 변경 범위에서 제외한다.
#
# [왜 ClusterSecretStore가 아니라 SecretStore(네임스페이스 스코프)인가]
# main.tf가 ClusterSecretStore를 쓴 이유는 blueprints가 관리하는 external-secrets-sa
# (external-secrets 네임스페이스에 고정, 수동 변경 금지 대상)를 재사용해야 했는데,
# 네임스페이스 스코프 SecretStore는 자기 자신과 같은 네임스페이스의 SA만 참조 가능해서
# (공식 이슈 external-secrets/external-secrets#366) 크로스 네임스페이스 참조가 필요했기
# 때문이다. 이번엔 새 커스텀 SA(notifications-eso-sa)를 Secret이 필요한 네임스페이스
# 안에 바로 만들므로 이 제약이 발생하지 않는다. 따라서 네임스페이스 스코프 SecretStore를
# 쓴다 — 이 Store를 쓰는 네임스페이스 자신 안에서만 SA를 참조할 수 있으므로 크로스
# 네임스페이스 참조 자체가 구조적으로 불가능해 GitHub App Store와 자연히 격리된다.
#
# [왜 IAM Role 1개로 SA 2개를 커버하는가]
# IAM 조건의 StringEquals value가 리스트면 OR 매칭이라 SA 2개(argo-rollouts,
# argocd 네임스페이스)를 동시에 신뢰할 수 있다 — 두 네임스페이스가 물리적으로
# 다른 SA를 갖되 같은 Role을 공유하는 구조다. 하나의 Role로 충분한 이유: 두 SA가
# 요구하는 권한이 완전히 동일하다 — 둘 다 Slack Bot Token 하나만 필요하다.
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
            "${local.oidc_provider_url}:sub" = [
              "system:serviceaccount:argo-rollouts:notifications-eso-sa",
              "system:serviceaccount:argocd:notifications-eso-sa",
            ]
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

resource "kubernetes_service_account_v1" "notifications_eso_argo_rollouts" {
  metadata {
    name      = "notifications-eso-sa"
    namespace = "argo-rollouts"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.notifications_slack.arn
    }
  }

  # argo-rollouts 네임스페이스는 이 root에서 별도로 생성하지 않는다 — module.eks_addons(Helm
  # 서브차트)가 자체적으로 생성한다 (argo-rollouts-notifications.tf 상단 주석과 동일 컨벤션).
  depends_on = [module.eks_addons]
}

resource "kubernetes_service_account_v1" "notifications_eso_argocd" {
  metadata {
    name      = "notifications-eso-sa"
    namespace = "argocd"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.notifications_slack.arn
    }
  }

  # argocd 네임스페이스는 이 root에서 별도로 생성하지 않는다 — module.eks_addons(Helm
  # 서브차트)가 자체적으로 생성한다 (argocd-notifications.tf 상단 주석과 동일 컨벤션).
  depends_on = [module.eks_addons]
}

# 네임스페이스 스코프 SecretStore는 conditions 필드가 없다 — 애초에 자기 네임스페이스
# 밖에서 참조 자체가 불가능하므로 "어떤 네임스페이스가 이 Store를 참조할 수 있는가"를
# 제한하는 defense-in-depth 계층(ClusterSecretStore의 conditions.namespaces)이 의미가 없다.
resource "kubernetes_manifest" "notifications_secret_store_argo_rollouts" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-parameterstore-notifications"
      namespace = "argo-rollouts"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = "ap-northeast-2"
          auth = {
            jwt = {
              serviceAccountRef = {
                name = kubernetes_service_account_v1.notifications_eso_argo_rollouts.metadata[0].name
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.eks_addons,
    kubernetes_service_account_v1.notifications_eso_argo_rollouts,
  ]
}

resource "kubernetes_manifest" "notifications_secret_store_argocd" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-parameterstore-notifications"
      namespace = "argocd"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = "ap-northeast-2"
          auth = {
            jwt = {
              serviceAccountRef = {
                name = kubernetes_service_account_v1.notifications_eso_argocd.metadata[0].name
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.eks_addons,
    kubernetes_service_account_v1.notifications_eso_argocd,
  ]
}
