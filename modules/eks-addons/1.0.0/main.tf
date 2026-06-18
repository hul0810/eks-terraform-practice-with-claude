################################################################################
# EKS Addons 모듈 — Helm (blueprints) 전용
#
# 관리 범위: AWS LB Controller, ExternalDNS, Metrics Server, Karpenter, ArgoCD, Argo Rollouts
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
  argocd_values = {
    global = {
      tolerations = [{
        key      = "CriticalAddonsOnly"
        operator = "Exists"
        effect   = "NoSchedule"
      }]
    }
    dex           = { enabled = false }
    notifications = { enabled = false }
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

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.23.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  # ── AWS Load Balancer Controller ─────────────────────────────────────────────
  # EKS 관리형 addon이 없는 Helm-only 컴포넌트. blueprints가 IRSA 자동 처리.
  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller = {
    chart_version        = var.lbc_chart_version
    role_name            = "${var.cluster_name}-lbc-irsa"
    role_name_use_prefix = false
    set = [
      # LBC v3.x는 vpcId 미지정 시 IMDS에서 VPC ID를 조회한다.
      # Pod에서 IMDSv2 hop limit(기본 1) 초과로 IMDS 접근이 불가하므로 직접 주입한다.
      { name = "vpcId", value = var.vpc_id },
      # 기본값 2 — dev는 replica_counts.lbc=1로 낮춰 시스템 노드 리소스를 확보한다
      { name = "replicaCount", value = tostring(var.replica_counts.lbc) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect", value = "NoSchedule" },
    ]
  }

  # ── ExternalDNS ───────────────────────────────────────────────────────────────
  # Route53 zone 설정 등 Helm values 커스터마이징이 필요하여 Helm으로 관리한다.
  # blueprints가 IRSA 자동 처리.
  # IRSA Role은 external_dns_route53_zone_arns 가 비어있으면 blueprints가 생성하지 않는다.
  # zone ARNs 설정 시 고정 이름으로 생성되도록 role_name을 미리 선언한다.
  enable_external_dns            = var.enable_external_dns
  external_dns_route53_zone_arns = var.external_dns_route53_zone_arns
  external_dns = {
    chart_version        = var.external_dns_chart_version
    role_name            = "${var.cluster_name}-external-dns-irsa"
    role_name_use_prefix = false
    set = [
      # 기본값 1이나 명시적으로 관리
      { name = "replicaCount", value = tostring(var.replica_counts.external_dns) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect", value = "NoSchedule" },
    ]
  }

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

  # ── Karpenter ─────────────────────────────────────────────────────────────────
  # blueprints가 컨트롤러 IAM Role, SQS 인터럽션 큐, EventBridge Rule, Helm chart를 통합 처리.
  # NodeClass / NodePool은 Kubernetes 리소스이므로 별도 관리한다.
  #
  # [배포 주의] 클러스터를 새로 생성한 직후 이 모듈을 처음 apply하면, karpenter
  # helm_release가 아래 오류로 실패할 수 있다:
  #   "failed calling webhook \"mservice.elbv2.k8s.aws\": ... no endpoints
  #    available for service \"aws-load-balancer-webhook-service\""
  # 원인: helm_release 리소스 간 명시적 순서가 없어 LBC와 karpenter가 동시에
  # 배포되는데, karpenter 차트가 생성하는 Service를 LBC의 mutating webhook이
  # 가로채려 하지만 LBC pod가 아직 Ready 상태가 아니다 (webhook Service에
  # endpoint 없음).
  # 해결: LBC pod가 Running이 될 때까지 대기 후 `terraform apply`를 재실행하면
  # 실패한 karpenter release만 tainted 상태로 재생성되며 정상 완료된다.
  enable_karpenter = var.enable_karpenter
  karpenter = {
    chart_version        = var.karpenter_chart_version
    role_name            = "${var.cluster_name}-karpenter-controller-irsa"
    role_name_use_prefix = false
    # Policy도 고정 이름 사용 — 미설정 시 Role 이름을 prefix로 random suffix가 붙는다
    policy_name            = "${var.cluster_name}-karpenter-controller-irsa"
    policy_name_use_prefix = false
    set = [
      # 기본값 2 — dev는 replica_counts.karpenter=1로 낮춰 시스템 노드 Pending 해소
      { name = "replicas", value = tostring(var.replica_counts.karpenter) },
      # 시스템 노드에 스케줄 — Karpenter 자체가 앱 노드에서 실행되면 부트스트랩 문제 발생
      { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect", value = "NoSchedule" },
    ]
  }

  # Karpenter 노드 IAM Role / Instance Profile
  # blueprints 기본값은 "karpenter-{cluster_name}-{random}" 형태.
  # 고정 이름으로 변경하여 멀티 클러스터 환경에서 식별이 쉽도록 한다.
  karpenter_node = {
    iam_role_name            = "${var.cluster_name}-karpenter-node"
    iam_role_use_name_prefix = false
  }

  # Karpenter SQS 인터럽션 큐 고정 이름
  # blueprints 기본값은 "karpenter-{cluster_name}" (prefix 역전).
  # {cluster_name}-karpenter 로 통일하여 다른 리소스와 네이밍 패턴을 맞춘다.
  karpenter_sqs = {
    queue_name = "${var.cluster_name}-karpenter"
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
  }

  # ── ArgoCD ────────────────────────────────────────────────────────────────────
  # GitOps 전환(Phase 5)의 시작점. AWS API를 호출하지 않으므로 IAM 불필요(metrics-server와 동일).
  # dex(SSO)·notifications는 미구성 상태이므로 비활성화 — 필요 시 이후 단계에서 활성화.
  # app-controller(controller.replicas)는 sharding 설정이 추가로 필요해 이 단계에서는 1로 유지.
  enable_argocd = var.enable_argocd
  argocd = {
    chart_version = var.argocd_chart_version
    values        = [yamlencode(local.argocd_values)]
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
  principal_arn = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  tags = var.additional_tags
}
