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
    # external_dns_assume_role_arn이 설정된 경우 --aws-assume-role 인자를 추가한다.
    # 실제 external-dns 바이너리 플래그는 --aws-assume-role이다 (--aws-assume-role-arn 아님).
    # concat 패턴: 빈 리스트와 병합하여 조건부로 extraArgs를 주입한다.
    set = concat(
      [
        { name = "replicaCount", value = tostring(var.replica_counts.external_dns) },
        { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
        { name = "tolerations[0].operator", value = "Exists" },
        { name = "tolerations[0].effect", value = "NoSchedule" },
      ],
      var.external_dns_assume_role_arn != "" ? [
        { name = "extraArgs[0]", value = "--aws-assume-role=${var.external_dns_assume_role_arn}" }
      ] : []
    )
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

  # ── External Secrets Operator ────────────────────────────────────────────────
  # AWS SSM Parameter Store/Secrets Manager의 값을 K8s Secret으로 동기화한다.
  # blueprints가 IRSA 자동 처리. IAM 정책은 blueprints 내부에서
  # `length(var.external_secrets_ssm_parameter_arns) > 0 ? [statement] : []` 패턴의
  # dynamic block으로 생성되므로, 이 모듈의 변수에 빈 리스트를 그대로 전달하면
  # blueprints의 기본 와일드카드 대신 "정책 문(statement) 자체가 생성되지 않아 권한 없음"으로
  # 귀결된다. 따라서 빈 리스트일 때는 blueprints 기본값과 동일한 와일드카드를 명시적으로
  # 전달해 "미지정 시 동작"을 그대로 재현한다.
  # SecretStore/ClusterSecretStore, ExternalSecret CR은 이 모듈의 관리 범위가 아니다
  # (환경 root module에서 관리 — 예: monitoring/.../eks-addons/main.tf).
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
    chart_version = var.external_secrets_chart_version
    # 다른 addon(LBC/ExternalDNS/Karpenter)과 동일하게 고정 이름 사용 — 멀티 클러스터 환경에서 식별 용이
    role_name            = "${var.cluster_name}-external-secrets-irsa"
    role_name_use_prefix = false
    set = [
      { name = "replicaCount", value = tostring(var.replica_counts.external_secrets) },
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
    # blueprints가 생성하는 기본 정책에는 iam:CreateServiceLinkedRole이 빠져있다.
    # spot capacity-type을 쓰는 NodePool에서 EC2 Spot 서비스 연결 역할
    # (AWSServiceRoleForEC2Spot)이 계정에 아직 없으면 Karpenter가 CreateFleet 시점에
    # 직접 생성을 시도하는데, 이 권한이 없어 AuthFailure.ServiceLinkedRoleCreationNotPermitted로
    # 계속 실패하고 spot Pod이 "no instance type has the required offering"이라는
    # (원인과 무관한) 메시지를 남긴 채 Pending 상태로 멈춘다. 서비스 연결 역할 자체는
    # 계정당 1회만 생성되면 되므로(관리자 권한으로 `aws iam create-service-linked-role
    # --aws-service-name spot.amazonaws.com` 1회 실행), 이 statement는 그 역할이 아직
    # 없는 새 계정에서도 Karpenter가 스스로 만들 수 있도록 하는 방어적 최소 권한이다.
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
