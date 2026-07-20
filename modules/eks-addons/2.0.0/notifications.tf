# ArgoCD Notifications-engine 설정(Slack) — main.tf/locals.tf에서 분리. 공식 카탈로그
# template/trigger를 그대로 옮긴 정적 보일러플레이트라 module 선언(main.tf)이나 핵심 계산
# 로직(locals.tf)과 섞이면 실제 리소스 구조를 파악하기 어려워져 별도 파일로 뺐다.
#
# Argo Rollouts용 Slack notifications 설정은 여기 없다 — Argo Rollouts는 처음부터 ArgoCD가
# Helm으로 설치·관리하고(devops-manifest), Terraform은 이 addon에 전혀 관여하지 않는다.
# Slack 설정도 devops-manifest의 values-override.yaml 쪽 관심사다.

locals {
  # ArgoCD Application Notifications — Slack. 3종만 구성한다(app-health-degraded/app-sync-failed/
  # app-sync-status-unknown) — "정상 동작은 알림 불필요" 원칙으로 on-deployed/on-sync-running/
  # on-sync-succeeded/on-created/on-deleted는 의도적으로 제외. templates는 공식 카탈로그
  # (argoproj/argo-cd notifications_catalog)와 구조가 달라 message+slack만 담은 경량 버전으로
  # 별도 작성했고, triggers는 공식 카탈로그의 when/oncePer/send/description을 그대로 사용한다
  # (ArgoCD Application은 이벤트가 아니라 상태를 계속 재평가하는 구조라 when 조건이 필수).
  argocd_notifications_values = var.argocd_notifications_slack_enabled ? {
    notifiers = {
      "service.slack" = <<-EOT
        token: $slack-token
      EOT
    }
    templates = {
      "template.app-health-degraded"     = <<-EOT
        message: Application {{.app.metadata.name}} is Degraded.
        slack:
          attachments: |
            [{
              "title": "{{.app.metadata.name}}",
              "color": "#E01E5A",
              "fields": [
                {"title": "Sync Status", "value": "{{.app.status.sync.status}}", "short": true},
                {"title": "Health Status", "value": "{{.app.status.health.status}}", "short": true},
                {"title": "Repository", "value": "{{.app.spec.source.repoURL}}", "short": false}
              ]
            }]
      EOT
      "template.app-sync-failed"         = <<-EOT
        message: Application {{.app.metadata.name}} sync has failed.
        slack:
          attachments: |
            [{
              "title": "{{.app.metadata.name}}",
              "color": "#E01E5A",
              "fields": [
                {"title": "Sync Status", "value": "{{.app.status.sync.status}}", "short": true},
                {"title": "Revision", "value": "{{.app.status.sync.revision}}", "short": true}
              ]
            }]
      EOT
      "template.app-sync-status-unknown" = <<-EOT
        message: Application {{.app.metadata.name}}'s sync status is Unknown.
        slack:
          attachments: |
            [{
              "title": "{{.app.metadata.name}}",
              "color": "#ECB22E",
              "fields": [
                {"title": "Sync Status", "value": "{{.app.status.sync.status}}", "short": true}
              ]
            }]
      EOT
    }
    triggers = {
      "trigger.on-health-degraded"     = <<-EOT
        - description: Application has degraded
          oncePer: app.status.operationState?.syncResult?.revision
          send:
          - app-health-degraded
          when: app.status.health.status == 'Degraded'
      EOT
      "trigger.on-sync-failed"         = <<-EOT
        - description: Application syncing has failed
          oncePer: app.status.operationState?.syncResult?.revision
          send:
          - app-sync-failed
          when: app.status.operationState != nil and app.status.operationState.phase in ['Error',
            'Failed']
      EOT
      "trigger.on-sync-status-unknown" = <<-EOT
        - description: Application status is 'Unknown'
          oncePer: app.status.operationState?.syncResult?.revision
          send:
          - app-sync-status-unknown
          when: app.status.sync.status == 'Unknown'
      EOT
    }
  } : {}
}
