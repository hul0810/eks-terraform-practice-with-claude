# main.tf에서 분리 — module/resource 선언과 값 조립 로직을 분리해 main.tf가 "이 모듈이
# 무엇을 선언하는가"를 한눈에 보여주도록 한다. Slack notifications 관련 대용량 보일러플레이트는
# notifications.tf로 별도 분리했다(이 파일이 참조는 하되 정의는 그쪽에 있음).

locals {
  # Argo Rollouts UI Extension 버전 고정. 이 프로젝트의 모든 Helm chart 버전 고정 원칙과 동일하게
  # "latest"가 아닌 특정 태그를 명시한다 — argocd-server pod 재시작(노드 교체, HPA 등 코드 변경과
  # 무관한 이벤트)마다 initContainer가 매번 새로 다운로드하므로, latest를 쓰면 git diff 없이도
  # 배포된 아티팩트가 바뀌는 상태가 된다. 업그레이드 시 이 값만 변경한다.
  rollout_extension_version = "v0.4.0"

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
      # 진행 상황을 표시한다. Argo Rollouts는 Terraform이 전혀 관여하지 않는 addon(devops-manifest의
      # ArgoCD Application이 전담)이라, "클러스터에 실제로 있는가"를 이 모듈이 알 방법이 없다 —
      # 그래서 root가 직접 값을 넘긴다(var.argo_rollouts_extension_enabled, 기본값 없음).
      # 릴리스 자산 실제 파일명은 extension.tar(.gz 아님) — v0.4.0 기준 GitHub Releases에서 확인.
      # EXTENSION_CHECKSUM_URL 미설정: rollout-extension 릴리스에 체크섬 파일 자체가 게시되지 않아
      # (v0.4.0 자산은 extension.tar 단일 파일) 검증 대상 URL이 없다. 버전 태그 고정이 현재
      # 확보 가능한 무결성 보장의 전부다.
      var.argo_rollouts_extension_enabled ? {
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

  # OTel Collector namespace 이름 단일 정의.
  # kubernetes_manifest의 metadata.namespace와 kubernetes_namespace_v1이 이 값을 공유하여
  # namespace 이름 변경 시 한 곳만 수정하면 된다.
  otel_collector_namespace = "otel-collector"
}
