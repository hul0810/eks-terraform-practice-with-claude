################################################################################
# EKS Addons 모듈 — GitOps Bridge 패턴 전용
#
# 관리 범위: AWS LB Controller, ExternalDNS, External Secrets Operator, Karpenter(IAM만),
#            ArgoCD(설치 + Hub 부트스트랩)
#
# GitOps Bridge 패턴을 쓴다는 것 자체가 addon의 Helm release는 ArgoCD가 관리한다는 뜻이다 —
# 이 모듈은 addon을 Terraform-Helm으로 먼저 들여왔다가 나중에 ArgoCD로 옮기는 "과도기 상태"를
# 더 이상 지원하지 않는다(과거엔 그런 인스턴스가 있었으나, 이 프로젝트의 모든 addon이
# ArgoCD 이관을 마친 뒤 제거했다 — 새 addon도 처음부터 ArgoCD가 Helm을 관리하고, 이 모듈은
# 필요한 경우(AWS API를 직접 호출하는 addon) IAM만 유지한다). IAM이 필요 없는 addon
# (metrics-server, argo-rollouts 등)은 이 모듈이 아예 관여하지 않는다 — devops-manifest의
# ArgoCD Application이 처음부터 전담한다.
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

# ArgoCD 설치 + GitOps Bridge Hub 부트스트랩 — gitops-bridge-dev/gitops-bridge/helm 사용.
# dex(SSO)·notifications는 미구성 상태이므로 비활성화 — 필요 시 이후 단계에서 활성화.
# app-controller(controller.replicas)는 sharding 설정이 추가로 필요해 이 단계에서는 1로
# 유지(local.argocd_values, locals.tf 참고).
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
# IAM(IRSA)은 계속 Terraform이 유지해야 하는 addon 전용 인스턴스
#
# module "gitops_bridge_bootstrap"(위)와 반대 성격이다: 그쪽은 "Helm은 Terraform이
# 영원히 유지"하는 부트스트랩 예외이고, 이쪽은 "IAM만 Terraform이 유지하고 Helm은 ArgoCD가
# 가져간" addon들을 모은다. create_kubernetes_resources를 항상 false로 고정한다 — 즉
# create(=enable_x)는 true로 두어 IAM Role/Policy는 계속 생성하되, create_release(Helm
# release)는 이 인스턴스 전체에서 절대 만들지 않는다.
#
# IAM이 필요한 새 addon이 생기면 이 인스턴스에 블록을 추가하기만 하면 된다 — addon마다 새
# 모듈 인스턴스를 만들 필요 없이 이 인스턴스를 계속 재사용. GitOps Bridge 패턴에서는 Helm이
# 처음부터 ArgoCD 몫이므로, "Terraform-Helm으로 먼저 들여왔다가 나중에 여기로 옮기는" 단계
# 자체가 없다 — IAM이 필요한 addon은 처음부터 여기서 시작한다.
#
# state 이전 시 유의:
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

  # ── AWS Load Balancer Controller ──────────────────────────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/aws-load-balancer-
  # controller)이 관리한다. 여기서는 IRSA(IAM Role/Policy)만 유지한다 — chart_version/
  # role_name/role_name_use_prefix 전부 이 모듈이 정하지 않는다(var.lbc_config, 호출자가
  # 자신의 네이밍 정책으로 결정). ArgoCD values의 serviceAccount.annotations가 가리키는 ARN이
  # 안 바뀌려면 호출자가 넘기는 값이 기존과 동일해야 한다 — 그 책임은 root에 있다.
  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller        = var.lbc_config

  # ── ExternalDNS ────────────────────────────────────────────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/external-dns)이
  # 관리한다. 여기서는 IRSA만 유지 — chart_version/role_name 등은 root가 결정(var.external_dns_config).
  enable_external_dns            = var.enable_external_dns
  external_dns_route53_zone_arns = var.external_dns_route53_zone_arns
  external_dns                   = var.external_dns_config

  # ── External Secrets Operator ─────────────────────────────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/external-secrets)이
  # 관리한다. 여기서는 IRSA만 유지 — IAM 스코프(ssm_parameter_arns/kms_key_arns)는 빈
  # 리스트일 때 blueprints 기본 와일드카드를 그대로 재현한다. chart_version/role_name 등은
  # root가 결정(var.external_secrets_config).
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
  external_secrets = var.external_secrets_config

  # ── Karpenter ──────────────────────────────────────────────────────────────────
  # Helm release는 ArgoCD Application(devops-manifest charts/eks-addons/karpenter)이
  # 관리한다. 여기서는 컨트롤러 IRSA + 노드 IAM Role/Instance Profile + SQS 인터럽션 큐를
  # 유지한다 — 전부 AWS 리소스라 Helm 이관 여부와 무관하게 계속 Terraform이 관리해야 한다.
  # EventBridge Rule/Target(SQS 인터럽션 큐 연동)은 vendor 모듈이 enable_karpenter=true일 때
  # 자동으로 함께 생성한다 — 별도 선언 불필요.
  # chart_version/role_name/policy_name 등은 root가 결정(var.karpenter_config) — 단
  # policy_statements만은 이 모듈이 강제 병합한다: blueprints 기본 정책에
  # iam:CreateServiceLinkedRole이 빠져있는 결함에 대한 정합성 fix이지 root의 정책적 선택이
  # 아니기 때문이다(variables.tf의 karpenter_config WHY 참고. 상세 사유:
  # modules/eks-addons/2.0.0/CLAUDE.md "Karpenter Spot capacity-type" 절 참조). root가 이
  # 객체에 자기 policy_statements를 추가로 넣으면 concat으로 합쳐지고, 안 넣어도 이 fix는
  # 항상 포함된다.
  enable_karpenter = var.enable_karpenter
  karpenter = merge(
    var.karpenter_config,
    {
      policy_statements = concat(
        try(var.karpenter_config.policy_statements, []),
        [
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
      )
    }
  )

  karpenter_node = var.karpenter_node_config
  karpenter_sqs  = var.karpenter_sqs_config

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
