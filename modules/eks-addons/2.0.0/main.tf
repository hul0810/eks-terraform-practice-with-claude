################################################################################
# EKS Addons 모듈 — Helm (blueprints) 전용
#
# 관리 범위: AWS LB Controller, ExternalDNS, Metrics Server, External Secrets Operator,
#            Karpenter, ArgoCD, Argo Rollouts
#
# 이 모듈은 EKS 관리형 addon API(aws_eks_addon)가 없거나 Helm values 커스터마이징이
# 필요한 애드온을 aws-ia/eks-blueprints-addons 모듈로 관리한다.
#
# [EBS CSI Driver를 여기서 관리하지 않는 이유]
# EBS CSI는 Bootstrap 애드온으로 분류되어 modules/eks에서 관리한다.
# (docs/addon-strategy.md의 "설치 방식 결정 기준" 참조)
#
# [IAM 전략: IRSA]
# blueprints 모듈이 IRSA를 표준으로 지원한다.
# oidc_provider_arn을 받아 blueprints 내부에서 IAM Role 생성과
# Helm values serviceAccount.annotations 주입을 자동 처리한다.
################################################################################

locals {
  # Argo Rollouts UI Extension 버전 고정. 이 프로젝트의 모든 Helm chart 버전 고정 원칙과 동일하게
  # "latest"가 아닌 특정 태그를 명시한다 — argocd-server pod 재시작(노드 교체, HPA 등 코드 변경과
  # 무관한 이벤트)마다 initContainer가 매번 새로 다운로드하므로, latest를 쓰면 git diff 없이도
  # 배포된 아티팩트가 바뀌는 상태가 된다. 업그레이드 시 이 값만 변경한다.
  rollout_extension_version = "v0.4.0"

  # var.argo_rollouts_extension_enabled가 null이면 기존 동작(enable_argo_rollouts를 그대로 따름)을
  # 유지한다 — variables.tf의 "GitOps Bridge 이관 후 enable_argo_rollouts의 의미 변화" 주석 참조.
  argo_rollouts_extension_enabled = (
    var.argo_rollouts_extension_enabled != null
    ? var.argo_rollouts_extension_enabled
    : var.enable_argo_rollouts
  )

  # Argo Rollouts Notifications — Slack 알림 서비스(notifiers) + 공식 기본 templates/triggers
  # 9종씩(argoproj/argo-rollouts 공식 저장소 manifests/notifications-install.yaml 기준, email
  # notifier용 항목은 이 프로젝트가 이메일 알림을 쓰지 않으므로 제외)을 함께 구성한다.
  # notifiers만으로는 알림이 발송되지 않는다 — trigger가 어떤 이벤트에서 어떤 template으로 보낼지
  # 정의하고, template이 실제 Slack 메시지 포맷을 정의해야 한다. 이 9개 trigger가 여기 준비되어
  # 있어야 GitOps 저장소(eks-practice-devops-manifest)에서 Rollout 리소스에
  # notifications.argoproj.io/subscriptions annotation을 붙였을 때 실제로 발송된다
  # (subscriptions 자체는 여전히 GitOps 저장소에서 Rollout annotation으로 관리 — Terraform 범위 밖).
  # $slack-token은 실제 토큰이 아니라 같은 네임스페이스의 argo-rollouts-notification-secret
  # Secret의 slack-token 키를 가리키는 notifications-engine 참조 문법이다.
  argo_rollouts_values = var.argo_rollouts_notifications_slack_enabled ? {
    notifications = {
      notifiers = {
        "service.slack" = <<-EOT
          token: $slack-token
        EOT
      }
      templates = {
        "template.analysis-run-error"     = <<-EOT
          message: Rollout {{.rollout.metadata.name}}'s analysis run is in error state.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#ECB22E",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.analysis-run-failed"    = <<-EOT
          message: Rollout {{.rollout.metadata.name}}'s analysis run failed.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#E01E5A",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.analysis-run-running"   = <<-EOT
          message: Rollout {{.rollout.metadata.name}}'s analysis run is running.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.rollout-aborted"        = <<-EOT
          message: Rollout {{.rollout.metadata.name}} has been aborted.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#E01E5A",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.rollout-completed"      = <<-EOT
          message: Rollout {{.rollout.metadata.name}} has been completed.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.rollout-paused"         = <<-EOT
          message: Rollout {{.rollout.metadata.name}} has been paused.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.rollout-step-completed" = <<-EOT
          message: Rollout {{.rollout.metadata.name}} step number {{ add .rollout.status.currentStepIndex 1}}/{{len .rollout.spec.strategy.canary.steps}} has been completed.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  },
                  {
                    "title": "Step completed",
                    "value": "{{add .rollout.status.currentStepIndex 1}}/{{len .rollout.spec.strategy.canary.steps}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.rollout-updated"        = <<-EOT
          message: Rollout {{.rollout.metadata.name}} has been updated.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
        "template.scaling-replicaset"     = <<-EOT
          message: Scaling Rollout {{.rollout.metadata.name}}'s replicaset to {{.rollout.spec.replicas}}.
          slack:
            attachments: |
                [{
                  "title": "{{ .rollout.metadata.name}}",
                  "color": "#18be52",
                  "fields": [
                  {
                    "title": "Strategy",
                    "value": "{{if .rollout.spec.strategy.blueGreen}}BlueGreen{{end}}{{if .rollout.spec.strategy.canary}}Canary{{end}}",
                    "short": true
                  },
                  {
                    "title": "Desired replica",
                    "value": "{{.rollout.spec.replicas}}",
                    "short": true
                  },
                  {
                    "title": "Updated replicas",
                    "value": "{{.rollout.status.updatedReplicas}}",
                    "short": true
                  }
                  {{range $index, $c := .rollout.spec.template.spec.containers}}
                    {{if not $index}},{{end}}
                    {{if $index}},{{end}}
                    {
                      "title": "{{$c.name}}",
                      "value": "{{$c.image}}",
                      "short": true
                    }
                  {{end}}
                  ]
                }]
        EOT
      }
      triggers = {
        "trigger.on-analysis-run-error"     = <<-EOT
          - send: [analysis-run-error]
        EOT
        "trigger.on-analysis-run-failed"    = <<-EOT
          - send: [analysis-run-failed]
        EOT
        "trigger.on-analysis-run-running"   = <<-EOT
          - send: [analysis-run-running]
        EOT
        "trigger.on-rollout-aborted"        = <<-EOT
          - send: [rollout-aborted]
        EOT
        "trigger.on-rollout-completed"      = <<-EOT
          - send: [rollout-completed]
        EOT
        "trigger.on-rollout-paused"         = <<-EOT
          - send: [rollout-paused]
        EOT
        "trigger.on-rollout-step-completed" = <<-EOT
          - send: [rollout-step-completed]
        EOT
        "trigger.on-rollout-updated"        = <<-EOT
          - send: [rollout-updated]
        EOT
        "trigger.on-scaling-replica-set"    = <<-EOT
          - send: [scaling-replicaset]
        EOT
      }
    }
  } : {}

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

  argocd_values = {
    global = {
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    }
    dex = { enabled = false }
    # GitOps Bridge 패턴: ArgoCD가 클러스터를 awsAuthConfig로 명시 등록하려면
    # application-controller ServiceAccount에 IRSA Role이 붙어 있어야 AWS IAM 인증이 가능하다.
    # 이 값이 Helm chart의 controller.serviceAccount.annotations 경로에 정확히 대응한다는 것을
    # `helm show values argo/argo-cd --version 9.5.21`로 직접 확인했다. null이면(기본값) 이
    # 블록 자체를 생략해 기존 in-cluster 암묵 등록만 쓰는 환경(dev/prd)에는 영향이 없다.
    controller = var.argocd_controller_irsa_role_arn != null ? {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.argocd_controller_irsa_role_arn
        }
      }
    } : {}
    # secret.create=false가 필요한 이유: argo-cd Helm chart의 notifications.secret.create 기본값이
    # true라 이대로 두면 Helm이 argocd-notifications-secret을 직접 생성하려 시도하고, 우리 쪽
    # ExternalSecret(argocd-notifications.tf)도 같은 이름의 Secret을 만들려 해서 소유권이 충돌한다.
    # false로 명시해 ESO(External Secrets Operator)가 전담하도록 한다.
    notifications = merge(
      {
        enabled = var.argocd_notifications_slack_enabled
        secret  = { create = false }
      },
      local.argocd_notifications_values
    )
    "redis-ha" = {
      enabled = var.argocd_ha_enabled
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    }
    server = merge(
      { replicas = var.argocd_ha_enabled ? var.replica_counts.argocd_server : 1 },
      # ALB Ingress: ACM 인증서로 TLS 종료, 백엔드는 server.insecure=true로 평문 HTTP.
      # ExternalDNS가 external-dns 어노테이션을 보고 argo-develop.pyhtest.com 레코드를 자동 생성한다
      # (external_dns_route53_zone_arns에 pyhtest.com zone ARN이 포함되어 있어야 함).
      var.argocd_ingress_enabled ? {
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          hostname         = var.argocd_ingress_hostname
          annotations = {
            "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"        = "ip"
            "alb.ingress.kubernetes.io/certificate-arn"    = var.argocd_ingress_acm_certificate_arn
            "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTPS\": 443}]"
            "alb.ingress.kubernetes.io/inbound-cidrs"      = join(",", var.argocd_ingress_allowed_cidrs)
            "alb.ingress.kubernetes.io/load-balancer-name" = var.argocd_ingress_alb_name
            "external-dns.alpha.kubernetes.io/hostname"    = var.argocd_ingress_hostname
          }
        }
      } : {},
      # Argo Rollouts UI Extension: argocd-server initContainer로 정적 파일을 받아와 UI에 canary/bluegreen
      # 진행 상황을 표시한다. Argo Rollouts 자체가 클러스터에 없는 환경에서는 표시할 대상이
      # 없으므로 local.argo_rollouts_extension_enabled에 종속시켜 무의미한 initContainer가
      # 뜨지 않도록 한다 — enable_argo_rollouts를 직접 쓰지 않는 이유는 variables.tf의
      # "GitOps Bridge 이관 후 enable_argo_rollouts의 의미 변화" 주석 참조.
      # 릴리스 자산 실제 파일명은 extension.tar(.gz 아님) — v0.4.0 기준 GitHub Releases에서 확인.
      # EXTENSION_CHECKSUM_URL 미설정: rollout-extension 릴리스에 체크섬 파일 자체가 게시되지 않아
      # (v0.4.0 자산은 extension.tar 단일 파일) 검증 대상 URL이 없다. 버전 태그 고정이 현재
      # 확보 가능한 무결성 보장의 전부다.
      local.argo_rollouts_extension_enabled ? {
        extensions = {
          enabled = true
          extensionList = [{
            name = "extension-rollout-extension"
            env = [
              {
                name  = "EXTENSION_URL"
                value = "https://github.com/argoproj-labs/rollout-extension/releases/download/${local.rollout_extension_version}/extension.tar"
              },
              {
                name  = "EXTENSION_VERSION"
                value = local.rollout_extension_version
              },
            ]
          }]
        }
      } : {}
    )
    repoServer     = { replicas = var.argocd_ha_enabled ? var.replica_counts.argocd_server : 1 }
    applicationSet = { replicaCount = var.argocd_ha_enabled ? var.replica_counts.argocd_server : 1 }
    # ALB가 TLS를 종료하므로 ArgoCD server는 평문 HTTP로 서빙 (argocd-cmd-params-cm: server.insecure)
    configs = merge(
      var.argocd_ingress_enabled ? {
        params = { "server.insecure" = true }
      } : {},
      # argocd_admin_password_bcrypt가 설정된 경우에만 secret 블록을 주입한다.
      # bcrypt 해시는 반드시 사전 계산된 고정값을 사용해야 한다. Terraform bcrypt() 함수를
      # 직접 사용하면 apply할 때마다 새 salt가 생성되어 argocd-secret이 매번 업데이트되고
      # ArgoCD server pod가 재시작된다.
      # argocdServerAdminPasswordMtime: ArgoCD가 패스워드 변경 여부를 판단하는 타임스탬프.
      # 패스워드를 재설정하려면 이 값도 함께 변경해야 ArgoCD가 새 해시를 반영한다.
      var.argocd_admin_password_bcrypt != "" ? {
        secret = {
          argocdServerAdminPassword      = var.argocd_admin_password_bcrypt
          argocdServerAdminPasswordMtime = var.argocd_admin_password_mtime
        }
      } : {}
    )
  }
}

################################################################################
# module.eks_blueprints_addons에서 ArgoCD를 아예 빼둔 이유 (Phase 6 리팩토링)
#
# aws-ia/terraform-aws-eks-blueprints-addons는 addon마다 별도 스위치(enable_metrics_server 등)를
# 두면서도, "Kubernetes 리소스(Helm release)를 실제로 만들지 여부"를 결정하는
# create_kubernetes_resources 변수는 그 모듈 인스턴스 전체에 걸쳐 단 하나뿐이다 — 소스를 직접
# 확인한 결과 argocd/metrics_server/karpenter 등 26개 addon 서브모듈이 전부
# `create_release = var.create_kubernetes_resources`로 예외 없이 같은 변수를 참조한다.
#
# 이 프로젝트는 GitOps Bridge(Phase 6)로 addon을 ArgoCD 관리로 하나씩 이관하면서도, ArgoCD
# 자신만은 부트스트랩 예외로 영원히 Terraform이 관리해야 한다(ArgoCD가 자기 자신을 GitOps로
# 관리할 수는 없다 — 관리 주체가 없어짐). ArgoCD는 이 모듈에 아예 넣지 않는다 — 아래
# module "gitops_bridge_bootstrap"이 전담한다(그 모듈 블록 상단 주석 참고 — blueprints로
# ArgoCD를 설치하지 않게 된 이유가 자세히 적혀 있다).
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.23.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  # GitOps Bridge(Phase 6) 최종 전환 스위치 — 위 섹션 설명 참고. ArgoCD는 이 module에 아예
  # 없으므로(module "gitops_bridge_bootstrap"이 전담) 이 스위치의 영향을 받지 않는다.
  create_kubernetes_resources = var.create_kubernetes_resources

  # ── Metrics Server ────────────────────────────────────────────────────────────
  # 순수 오픈소스. IAM 불필요.
  enable_metrics_server = var.enable_metrics_server
  metrics_server = {
    chart_version = var.metrics_server_chart_version
    set = [
      # 기본값 1이나 명시적으로 관리
      { name = "replicas", value = tostring(var.replica_counts.metrics_server) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect", value = "NoSchedule" },
    ]
  }

  # ── Argo Rollouts ─────────────────────────────────────────────────────────────
  # Canary·Blue-Green 배포 전략을 Kubernetes에서 구현한다.
  # AWS API를 직접 호출하지 않으므로 IAM 불필요 (metrics-server·ArgoCD와 동일).
  # ALB Ingress와 연동하는 경우 LBC 의존성이 생기므로 LBC보다 나중에 배포된다.
  enable_argo_rollouts = var.enable_argo_rollouts
  argo_rollouts = {
    chart_version = var.argo_rollouts_chart_version
    set = [
      # 기본값 2 — dev는 replica_counts.argo_rollouts=1로 낮춰 시스템 노드 리소스 확보
      { name = "controller.replicas", value = tostring(var.replica_counts.argo_rollouts) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "controller.tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "controller.tolerations[0].operator", value = "Exists" },
      { name = "controller.tolerations[0].effect", value = "NoSchedule" },
    ]
    values = [yamlencode(local.argo_rollouts_values)]
  }

  tags = var.additional_tags
}

# ArgoCD 설치 + GitOps Bridge Hub 부트스트랩 — gitops-bridge-dev/gitops-bridge/helm 사용.
# GitOps 전환(Phase 5)의 시작점. dex(SSO)·notifications는 미구성 상태이므로 비활성화 —
# 필요 시 이후 단계에서 활성화. app-controller(controller.replicas)는 sharding 설정이
# 추가로 필요해 이 단계에서는 1로 유지(local.argocd_values, 위 참고).
#
# [WHY — blueprints가 아니라 이 모듈로 ArgoCD를 설치하는 이유]
# 원래는 blueprints(aws-ia/eks-blueprints-addons)의 module "argocd" 서브모듈로 ArgoCD를
# 설치하고("eks_blueprints_addons_argocd"라는 별도 인스턴스), Hub 등록용 cluster Secret은
# root(gitops-bridge-irsa.tf)에 kubernetes_secret_v1으로 손코드 작성했었다. 이 구조를 재검토한
# 계기는 "ArgoCD 자신의 IRSA(argocd-application-controller SA)를 blueprints가 지원하는가"라는
# 질문이었다 — aws-ia/eks-blueprints-addon(범용 단일 addon 모듈)은 create_role/oidc_providers
# 등을 지원하지만, aws-ia/eks-blueprints-addons(복수형 wrapper)의 module "argocd" 호출부는
# 다른 13개 addon(aws_load_balancer_controller, external_dns, karpenter 등)과 달리 그 인자들을
# 전혀 forward하지 않는다는 걸 소스에서 직접 확인했다(temp/gitops-bridge-terraform-notes.md
# 7번 참고). 즉 blueprints는 ArgoCD 설치에 있어 얻을 이점이 하나도 없었다 — IRSA도 못 주고,
# Helm 설치는 다른 25개 addon과 똑같은 얇은 wrapper일 뿐이라 별도 인스턴스로 분리해 둘 이유가
# 사라졌다.
#
# gitops-bridge-dev/gitops-bridge/helm은 ArgoCD Helm 설치(install)와 GitOps Bridge Hub의
# cluster Secret(cluster) + App-of-Apps 부트스트랩(apps)을 한 모듈 인터페이스로 제공한다.
# 단, 이 모듈도 IAM 관련 리소스는 전혀 만들지 않는다(temp 문서 8번 참고) — ArgoCD 자신의
# IRSA(IAM Role/Access Entry/RBAC)는 root의 gitops-bridge-irsa.tf에 여전히 손코드로 남는다
# (blueprints든 이 모듈이든 어느 vendor도 "Hub 자신의 IRSA"는 대신 해주지 않는다).
#
# [WHY — cluster/apps를 nullable 변수(var.gitops_bridge_hub)로 받는 이유]
# 이 모듈 인스턴스는 공유 모듈(모든 환경이 재사용)에 있지만, cluster Secret·App-of-Apps는
# "이 클러스터가 GitOps Bridge Hub인가"라는 환경별 개념이다(develop/production이 나중에 이
# 모듈로 이관되면 spoke가 될 뿐 Hub가 아니다). "Hub 전용 로직이니 공유 모듈이 아니라 root에
# 둬야 한다"고 생각했었지만, 그건 "데이터가 어디 있는가"와 "이게 Hub 개념에 속하는가"를
# 혼동한 것이었다(temp 문서 9번 참고) — var.gitops_bridge_hub가 null이면 아래 두 리소스가
# 전혀 생성되지 않고, monitoring(Hub)만 root에서 실제 값을 채워 넘긴다. spoke가 될 환경은
# 이 변수를 안 넘기기만 하면 코드 수정 없이 자연스럽게 spoke로 동작한다.
#
# [WHY — cluster.metadata의 merge를 root가 아니라 여기(공유 모듈 내부)에서 하는 이유]
# root가 넘기는 var.gitops_bridge_hub.cluster.metadata에는 root에서만 계산 가능한 값
# (image-updater Role ARN 등)만 담고, 각 addon의 IRSA Role ARN 같은 값(module
# "eks_blueprints_addons_gitops"의 공식 output "gitops_metadata")은 여기서 형제 module을
# 직접 참조해 합친다. root에서 먼저 이 둘을 합쳐 넘기면 "module.eks_addons의 출력을 같은
# module.eks_addons 호출의 입력으로 되먹이는" 순환 참조가 되어 Terraform이 거부한다 — 이건
# 실제로 작성하다가 걸린 실수다. 같은 부모 모듈 안의 형제 module 참조는 순환이 아니므로,
# 이 merge는 반드시 root가 아니라 여기서 이뤄져야 한다.
module "gitops_bridge_bootstrap" {
  source = "gitops-bridge-dev/gitops-bridge/helm"
  # 프로젝트 컨벤션(공식 모듈 버전 "~> X.Y.Z", 패치만 허용)에 맞춰 패치 범위로 고정한다.
  # 이 모듈은 v0.1.0 단일 릴리스뿐이고 2024-04-14 이후 갱신이 없어(review-terraform,
  # aws-architect 리뷰에서 공통 지적) "~> 0.1"(마이너까지 허용)로 두면 향후 0.2.0이 게시될 때
  # 검증 없이 자동 채택될 여지가 있다.
  version = "~> 0.1.0"

  create  = var.enable_argocd
  install = var.enable_argocd
  argocd = {
    chart_version = var.argocd_chart_version
    values        = [yamlencode(local.argocd_values)]
  }

  # null이면(spoke) 아래 두 리소스가 생성되지 않는다 — 위 WHY 참고.
  # var.gitops_bridge_hub.cluster를 try()로 감싸는 이유(review-terraform 지적): apps처럼
  # cluster도 벤더 스키마상 optional이라, 호출자가 gitops_bridge_hub는 채우되 cluster 키를
  # 생략하는 부분 사용을 시도하면 이 try() 없이는 merge()가 즉시 에러를 낸다.
  cluster = var.gitops_bridge_hub == null ? null : merge(
    try(var.gitops_bridge_hub.cluster, {}),
    {
      metadata = merge(
        try(var.gitops_bridge_hub.cluster.metadata, {}),
        module.eks_blueprints_addons_gitops.gitops_metadata,
        {
          # module.eks_blueprints_addons_gitops.gitops_metadata(벤더의 gitops_metadata)는
          # 이 프로젝트 세팅에서 karpenter_node_iam_role_name을 채워주지 않는다(벤더가 노드
          # Role을 직접 안 만들고 karpenter_node 블록이 만드는 구조라 생기는 차이 —
          # outputs.tf의 karpenter_node_iam_role_name output과 동일한 이유). 검증된 값으로
          # 명시적으로 덮어쓴다 — merge() 순서상 맨 뒤에 둬 벤더 값과 충돌해도 이게 이긴다.
          karpenter_node_iam_role_name = module.eks_blueprints_addons_gitops.karpenter.node_iam_role_name
        }
      )
    }
  )
  apps = try(var.gitops_bridge_hub.apps, {})
}

# 옛 module "eks_blueprints_addons_argocd"(aws-ia/eks-blueprints-addons 기반)에서 이 module
# "gitops_bridge_bootstrap"(gitops-bridge-dev/gitops-bridge/helm 기반)으로 ArgoCD 설치
# 주체를 교체하면서 생기는 state 주소 변경은 moved 블록으로 처리할 수 없다 — source 자체가
# 다른 벤더 모듈로 바뀌어 Terraform이 "동일 리소스의 이동"으로 인식할 근거가 없기 때문이다
# (moved 블록은 같은 provider/schema 안에서의 주소 변경만 지원한다). 리소스 타입
# (helm_release)은 동일하므로 아래처럼 1회성 명령형 terraform state mv로 옮긴다:
#
#   terraform state mv \
#     'module.eks_addons.module.eks_blueprints_addons_argocd.module.argocd.helm_release.this[0]' \
#     'module.eks_addons.module.gitops_bridge_bootstrap.helm_release.argocd[0]'
#
# root의 kubernetes_secret_v1.argocd_cluster_self(손코드, gitops-bridge-irsa.tf)도 동일한
# 이유로 state mv 대상이다:
#
#   terraform state mv \
#     'kubernetes_secret_v1.argocd_cluster_self' \
#     'module.eks_addons.module.gitops_bridge_bootstrap.kubernetes_secret_v1.cluster[0]'

################################################################################
# module "eks_blueprints_addons_gitops" — GitOps Bridge로 ArgoCD 관리로 이관됐지만
# IAM(IRSA)은 계속 Terraform이 유지해야 하는 addon 전용 인스턴스 (Phase 6-3~)
#
# module "gitops_bridge_bootstrap"(위)와 반대 성격이다: 그쪽은 "Helm은 Terraform이
# 영원히 유지"하는 부트스트랩 예외이고, 이쪽은 "IAM만 Terraform이 유지하고 Helm은 ArgoCD가
# 가져간" addon들을 모은다. create_kubernetes_resources를 항상 false로 고정한다 — 즉
# create(=enable_x)는 true로 두어 IAM Role/Policy는 계속 생성하되, create_release(Helm
# release)는 이 인스턴스 전체에서 절대 만들지 않는다.
#
# LBC가 첫 입주자다(Phase 6-3). 이후 6-4에서 Karpenter/ExternalDNS/External Secrets 등을
# 이관할 때도 "rest" 인스턴스(module "eks_blueprints_addons")에서 해당 addon 블록을 여기로
# 옮기기만 하면 된다 — addon마다 새 모듈 인스턴스를 만들 필요 없이 이 인스턴스를 계속 재사용.
#
# state 이전 시 유의 (LBC 최초 이관 때 실제로 밟은 절차):
#   1. ArgoCD Application이 sync를 통해 Helm release를 실제로 인수했는지 먼저 검증한다
#      (diff가 tracking annotation뿐인지, sync 후 파드/ALB 등에 이상 없는지) — 검증 전에는
#      Terraform의 helm_release를 절대 건드리지 않는다(검증 실패 시 되돌릴 안전망 유지).
#   2. 검증 통과 후: IAM 리소스(aws_iam_role/aws_iam_policy/aws_iam_role_policy_attachment)는
#      `terraform state mv`로 이 인스턴스의 새 주소로 옮긴다(실제 AWS 리소스는 그대로 유지).
#   3. helm_release는 `terraform state rm`으로 Terraform 추적에서만 제거한다(destroy 아님 —
#      ArgoCD가 이미 그 리소스를 관리 중이므로 Terraform이 손을 뗄 뿐).
################################################################################

module "eks_blueprints_addons_gitops" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.23.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  # 이 인스턴스는 항상 Helm release를 만들지 않는다 — 여기 들어오는 addon은 전부 ArgoCD가
  # Helm을 관리하고 Terraform은 IAM만 유지한다는 게 이 인스턴스의 존재 이유이므로, 변수로
  # 노출하지 않고 고정한다.
  create_kubernetes_resources = false

  # ── AWS Load Balancer Controller (Phase 6-3, GitOps Bridge 이관 완료) ─────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/aws-load-balancer-
  # controller)이 관리한다. 여기서는 IRSA(IAM Role/Policy)만 유지한다 — role_name 등은
  # 기존과 동일하게 고정해 ArgoCD values의 serviceAccount.annotations가 가리키는 ARN이
  # 바뀌지 않게 한다.
  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller = {
    chart_version        = var.lbc_chart_version
    role_name            = "${var.cluster_name}-lbc-irsa"
    role_name_use_prefix = false
  }

  # ── ExternalDNS (Phase 6-4, GitOps Bridge 이관 완료) ──────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/external-dns)이
  # 관리한다. 여기서는 IRSA만 유지.
  enable_external_dns            = var.enable_external_dns
  external_dns_route53_zone_arns = var.external_dns_route53_zone_arns
  external_dns = {
    chart_version        = var.external_dns_chart_version
    role_name            = "${var.cluster_name}-external-dns-irsa"
    role_name_use_prefix = false
  }

  # ── External Secrets Operator (Phase 6-4, GitOps Bridge 이관 완료) ───────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/external-secrets)이
  # 관리한다. 여기서는 IRSA만 유지 — IAM 스코프(ssm_parameter_arns/kms_key_arns)는 원래
  # 빈 리스트일 때 blueprints 기본 와일드카드를 재현하는 로직을 그대로 가져온다(main.tf
  # "rest" 인스턴스였을 때와 동일한 이유).
  enable_external_secrets = var.enable_external_secrets
  external_secrets_ssm_parameter_arns = (
    length(var.external_secrets_ssm_parameter_arns) > 0
    ? var.external_secrets_ssm_parameter_arns
    : ["arn:aws:ssm:*:*:parameter/*"] # blueprints 기본값과 동일
  )
  external_secrets_kms_key_arns = (
    length(var.external_secrets_kms_key_arns) > 0
    ? var.external_secrets_kms_key_arns
    : ["arn:aws:kms:*:*:key/*"] # blueprints 기본값과 동일
  )
  external_secrets = {
    chart_version        = var.external_secrets_chart_version
    role_name            = "${var.cluster_name}-external-secrets-irsa"
    role_name_use_prefix = false
  }

  # ── Karpenter (Phase 6-4, GitOps Bridge 이관 완료) ────────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/karpenter)이
  # 관리한다. 여기서는 컨트롤러 IRSA + 노드 IAM Role/Instance Profile + SQS 인터럽션 큐를
  # 유지한다 — 전부 AWS 리소스라 Helm 이관 여부와 무관하게 계속 Terraform이 관리해야 한다.
  # EventBridge Rule/Target(SQS 인터럽션 큐 연동)은 vendor 모듈이 enable_karpenter=true일 때
  # 자동으로 함께 생성한다 — 별도 선언 불필요.
  enable_karpenter = var.enable_karpenter
  karpenter = {
    chart_version          = var.karpenter_chart_version
    role_name              = "${var.cluster_name}-karpenter-controller-irsa"
    role_name_use_prefix   = false
    policy_name            = "${var.cluster_name}-karpenter-controller-irsa"
    policy_name_use_prefix = false
    # blueprints 기본 정책에 iam:CreateServiceLinkedRole이 빠져있는 문제 대응.
    # 상세 사유: modules/eks-addons/2.0.0/CLAUDE.md "Karpenter Spot capacity-type" 절 참조.
    policy_statements = [
      {
        sid       = "AllowScopedEC2SpotServiceLinkedRoleCreation"
        actions   = ["iam:CreateServiceLinkedRole"]
        resources = ["arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"]
        conditions = [{
          test     = "StringEquals"
          variable = "iam:AWSServiceName"
          values   = ["spot.amazonaws.com"]
        }]
      }
    ]
  }

  karpenter_node = {
    iam_role_name            = "${var.cluster_name}-karpenter-node"
    iam_role_use_name_prefix = false
  }

  karpenter_sqs = {
    queue_name = "${var.cluster_name}-karpenter"
  }

  tags = var.additional_tags
}

# Karpenter 노드 IAM Role을 위한 EKS Access Entry
#
# 문제: eks-blueprints-addons의 karpenter 서브모듈은 노드 IAM Role/Instance Profile만 생성하고
# EKS Access Entry는 생성하지 않는다. authentication_mode가 API 또는 API_AND_CONFIG_MAP인
# 클러스터에서는 access entry가 없는 IAM Role의 EC2 인스턴스는 kubelet이
# "Unauthorized" 오류로 노드 등록에 실패한다 (EKS managed node group은 노드그룹 생성 시
# access entry가 자동 생성되지만, Karpenter 노드 Role은 수동 등록이 필요하다).
#
# 해결: EC2_LINUX 타입 access entry를 생성한다. 이 타입은 system:nodes / system:bootstrappers
# 그룹 매핑이 내장되어 있어 별도 access policy association이 필요 없다.
resource "aws_eks_access_entry" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = module.eks_blueprints_addons_gitops.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = var.additional_tags
}

# ── OTel Spoke Collector ──────────────────────────────────────────────────────
# dev/prd 클러스터에서 텔레메트리를 수집하여 monitoring 클러스터의 OTel Gateway로 전송한다.
#
# [수집 아키텍처: DaemonSet + Deployment 분리]
# k8s_cluster receiver는 K8s API를 폴링하여 Deployment·Pod 상태 등 클러스터 수준 메트릭을 수집한다.
# DaemonSet에 포함하면 노드 수만큼 중복 메트릭이 발생하므로 단일 Deployment로 분리한다.
#
# - otel-spoke-node   (DaemonSet):          노드별 kubeletstats 메트릭 + filelog 컨테이너 로그
# - otel-spoke-singleton (Deployment, 1):   클러스터 메트릭(k8s_cluster) + 앱 트레이스(otlp)
#
# [사전 조건] OTel Operator CRD가 설치되어 있어야 kubernetes_manifest가 plan/apply된다.
# cert-manager Bootstrap 애드온(modules/eks)이 먼저 배포되어 있어야 Operator webhook 인증서가 발급된다.
#
# [GitOps 전환] Phase 6에서 helm_release.otel_operator_spoke와 kubernetes_manifest.*를
# ArgoCD Application으로 이관한다. CLAUDE.md의 GitOps 전환 계획 참조.

locals {
  # OTel Collector namespace 이름 단일 정의.
  # kubernetes_manifest의 metadata.namespace와 kubernetes_namespace_v1이 이 값을 공유하여
  # namespace 이름 변경 시 한 곳만 수정하면 된다.
  otel_collector_namespace = "otel-collector"
}

resource "kubernetes_namespace_v1" "otel_collector" {
  count = var.enable_otel_spoke_collector ? 1 : 0

  metadata {
    name = local.otel_collector_namespace
  }
}

resource "helm_release" "otel_operator_spoke" {
  count = var.enable_otel_spoke_collector ? 1 : 0

  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = var.otel_spoke_operator_chart_version
  namespace        = "opentelemetry-operator-system"
  create_namespace = true

  values = [
    yamlencode({
      admissionWebhooks = {
        certManager = {
          enabled = true
        }
      }
      manager = {
        collectorImage = {
          repository = "otel/opentelemetry-collector-k8s"
        }
      }
    })
  ]
}

# ── OTel Spoke Node Collector (DaemonSet) ─────────────────────────────────────
# 노드당 1개 Pod. 노드 메트릭(kubeletstats)과 컨테이너 로그(filelog)를 수집한다.
# /var/log/pods 를 hostPath로 마운트하여 컨테이너 로그에 접근한다.
resource "kubernetes_manifest" "otel_spoke_node" {
  count = var.enable_otel_spoke_collector ? 1 : 0

  manifest = {
    apiVersion = "opentelemetry.io/v1beta1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = "otel-spoke-node"
      namespace = local.otel_collector_namespace
    }
    spec = {
      mode = "daemonset"
      config = {
        receivers = {
          kubeletstats = {
            collection_interval  = "30s"
            auth_type            = "serviceAccount"
            insecure_skip_verify = true
          }
          filelog = {
            include = ["/var/log/pods/*/*/*.log"]
            # "end": Pod 재시작 시 이미 전송된 로그 중복 방지.
            # 초기 배포 시 기존 로그가 수집되지 않는 trade-off 있음.
            # offset 영속화가 필요하면 filestorage extension 추가 검토.
            start_at          = "end"
            include_file_path = true
            include_file_name = false
          }
        }
        processors = {
          k8sattributes = {
            auth_type   = "serviceAccount"
            passthrough = false
            extract = {
              metadata = ["k8s.namespace.name", "k8s.deployment.name", "k8s.pod.name", "k8s.node.name"]
            }
          }
          resource = {
            attributes = [
              {
                action = "upsert"
                key    = "cluster"
                value  = var.cluster_name
              }
            ]
          }
          batch = {}
        }
        exporters = {
          otlp = {
            endpoint = var.otel_gateway_endpoint
            tls = {
              insecure = true
            }
          }
        }
        service = {
          pipelines = {
            metrics = {
              receivers  = ["kubeletstats"]
              processors = ["k8sattributes", "resource", "batch"]
              exporters  = ["otlp"]
            }
            logs = {
              receivers  = ["filelog"]
              processors = ["k8sattributes", "resource", "batch"]
              exporters  = ["otlp"]
            }
          }
        }
      }
      volumeMounts = [
        {
          name      = "varlogpods"
          mountPath = "/var/log/pods"
          readOnly  = true
        }
      ]
      volumes = [
        {
          name = "varlogpods"
          hostPath = {
            path = "/var/log/pods"
          }
        }
      ]
    }
  }

  depends_on = [
    helm_release.otel_operator_spoke,
    kubernetes_namespace_v1.otel_collector,
  ]
}

# ── OTel Spoke Singleton Collector (Deployment, 1 replica) ────────────────────
# 클러스터당 1개 Pod. K8s 오브젝트 메트릭(k8s_cluster)과 앱 트레이스·메트릭(otlp)을 수집한다.
# 앱 계측(Instrumentation) 활성화 전에는 otlp 파이프라인이 유휴 상태로 대기한다.
resource "kubernetes_manifest" "otel_spoke_singleton" {
  count = var.enable_otel_spoke_collector ? 1 : 0

  manifest = {
    apiVersion = "opentelemetry.io/v1beta1"
    kind       = "OpenTelemetryCollector"
    metadata = {
      name      = "otel-spoke-singleton"
      namespace = local.otel_collector_namespace
    }
    spec = {
      mode     = "deployment"
      replicas = 1
      config = {
        receivers = {
          k8s_cluster = {
            collection_interval = "30s"
            auth_type           = "serviceAccount"
          }
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
        }
        processors = {
          k8sattributes = {
            auth_type   = "serviceAccount"
            passthrough = false
            extract = {
              metadata = ["k8s.namespace.name", "k8s.deployment.name", "k8s.pod.name", "k8s.node.name"]
            }
          }
          resource = {
            attributes = [
              {
                action = "upsert"
                key    = "cluster"
                value  = var.cluster_name
              }
            ]
          }
          batch = {}
        }
        exporters = {
          otlp = {
            endpoint = var.otel_gateway_endpoint
            tls = {
              insecure = true
            }
          }
        }
        service = {
          pipelines = {
            metrics = {
              receivers  = ["k8s_cluster"]
              processors = ["k8sattributes", "resource", "batch"]
              exporters  = ["otlp"]
            }
            traces = {
              receivers  = ["otlp"]
              processors = ["k8sattributes", "resource", "batch"]
              exporters  = ["otlp"]
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.otel_operator_spoke,
    kubernetes_namespace_v1.otel_collector,
  ]
}
