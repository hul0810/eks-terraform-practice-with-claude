################################################################################
# Argo Rollouts Notifications — Slack Bot Token 동기화 (ESO)
#
# SSM Parameter Store(SecureString)에 등록된 Slack Bot Token을 External Secrets
# Operator(ESO)로 읽어 Argo Rollouts Notifications 컨트롤러가 기대하는 Secret으로 동기화한다.
#
# [Secret 이름/네임스페이스/키가 하드코딩인 이유]
# Argo Rollouts Notifications 컨트롤러는 아래 값을 컨벤션으로 고정 참조한다(공식 문서:
# https://argo-rollouts.readthedocs.io/en/stable/features/notifications/#configuration).
# 이름·네임스페이스·키 중 하나라도 어긋나면 컨트롤러가 Secret을 찾지 못해 Slack 알림이 조용히
# 실패한다 — target.name/namespace/data[].secretKey를 변수화하지 않고 그대로 리터럴로 둔다.
#   Secret 이름: argo-rollouts-notification-secret
#   네임스페이스: argo-rollouts
#   키: slack-token
#
# argo-rollouts 네임스페이스는 이 root에서 별도로 생성하지 않는다 — enable_argo_rollouts=true일
# 때 eks-blueprints-addons의 argo-rollouts Helm 서브차트가 자체적으로 생성한다
# (modules/eks-addons/1.0.0/main.tf 289~304행, 다른 애드온과 동일 컨벤션).
#
# [SSM 경로는 ArgoCD Application Notifications와 공용]
# Slack Bot Token은 Argo Rollouts Notifications와 ArgoCD Application Notifications
# (argocd-notifications.tf)가 동일한 Slack App/Bot을 공유하므로, 공용 경로
# (/eks-practice/notifications/slack-bot-token)를 함께 참조한다. 기존에는 이 애드온 전용
# 경로(/eks-practice/argo-rollouts/slack-bot-token)를 사용했으나 ArgoCD 알림 추가를 계기로
# 공용 경로로 이관했다.
#
# [SSM 파라미터는 Terraform 외부 관리 리소스]
# 이 프로젝트는 시크릿 값을 담는 SSM 파라미터를 Terraform이 생성하지 않는다 — SecureString 값이
# plan/state에 평문으로 노출되지 않도록 항상 AWS CLI로 수동 등록하고 Terraform은 ARN 참조만
# 한다(main.tf의 aws_parameterstore_secret_store와 동일 컨벤션). 아직 파라미터가 없다면 아래 명령으로 등록:
#
#   aws ssm put-parameter --name "/eks-practice/notifications/slack-bot-token" \
#     --type SecureString --value "<Slack Bot Token>" \
#     --region ap-northeast-2 --profile terraform-monitoring
#
# [전용 SecretStore(네임스페이스 스코프)를 쓰는 이유 — GitHub App Store와 분리된 신뢰 경계]
# 이 ExternalSecret은 main.tf의 공용 ClusterSecretStore(aws-parameterstore, GitHub App
# Private Key/Image Updater git-creds 겸용)를 더 이상 재사용하지 않는다. 대신 Slack Bot
# Token 전용 SecretStore(notifications-irsa.tf의 notifications_secret_store_argo_rollouts)를
# 쓴다. 상세 사유(보안 리뷰 배경, ClusterSecretStore가 아닌 이유)는 notifications-irsa.tf
# 상단 주석 참조.

resource "kubernetes_manifest" "argo_rollouts_notification_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "argo-rollouts-notification-secret"
      namespace = "argo-rollouts"
    }
    spec = {
      secretStoreRef = {
        name = kubernetes_manifest.notifications_secret_store_argo_rollouts.manifest.metadata.name
        kind = "SecretStore"
      }
      refreshInterval = "1h"
      target = {
        name           = "argo-rollouts-notification-secret"
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "slack-token"
          remoteRef = { key = "/eks-practice/notifications/slack-bot-token" }
        },
      ]
    }
  }

  depends_on = [
    module.eks_addons,
    kubernetes_manifest.notifications_secret_store_argo_rollouts,
  ]
}
