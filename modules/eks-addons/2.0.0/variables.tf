################################################################################
# EKS Addons 모듈 입력 변수
################################################################################

variable "cluster_name" {
  description = "EKS 클러스터 이름. eks-blueprints-addons 모듈의 필수 입력값"
  type        = string

  validation {
    # IAM Role 이름 최대 64자. 가장 긴 접미사 "-karpenter-controller-irsa" = 25자.
    # cluster_name + 25 <= 64 → cluster_name <= 39자. 여유분 1자 포함해 38자로 제한.
    condition     = length(var.cluster_name) <= 38
    error_message = "cluster_name은 38자 이하여야 합니다. IAM Role 이름 64자 제한으로 인해 '-karpenter-controller-irsa'(25자) 접미사를 포함하면 초과합니다."
  }
}

variable "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트 URL. eks-blueprints-addons 모듈의 필수 입력값"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes 버전 (예: \"1.33\"). eks-blueprints-addons의 Helm chart 호환성 확인에 사용"
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version은 \"1.XX\" 형식이어야 합니다 (예: \"1.33\")."
  }
}

variable "oidc_provider_arn" {
  description = "IRSA용 OIDC Provider ARN. blueprints 모듈이 LBC·ExternalDNS·Karpenter IAM Role 생성에 사용한다"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/", var.oidc_provider_arn))
    error_message = "oidc_provider_arn은 유효한 OIDC Provider ARN이어야 합니다."
  }
}

variable "vpc_id" {
  description = "EKS 클러스터가 속한 VPC ID. LBC의 Helm release가 ArgoCD로 이관되며 이 값(devops-manifest의 charts/eks-addons/aws-load-balancer-controller/values-override.yaml의 vpcId)도 함께 옮겨가 이 모듈에서는 현재 실제 사용처가 없다. vpc_id가 필요한 다른 addon이 eks_blueprints_addons_gitops로 이관되면 그때 다시 쓰일 수 있어 인터페이스는 유지한다."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id는 \"vpc-\" 접두사로 시작하는 유효한 VPC ID이어야 합니다 (예: \"vpc-0a1b2c3d4e5f67890\")."
  }
}

variable "enable_aws_load_balancer_controller" {
  description = "AWS Load Balancer Controller IAM(IRSA Role/Policy) 생성 여부. eks_blueprints_addons_gitops 인스턴스에서 create_kubernetes_resources가 항상 false로 고정되어 있어, 이 변수는 Helm release가 아니라 IAM 리소스 생성 여부만 제어한다 — Helm release는 ArgoCD(devops-manifest charts/eks-addons/aws-load-balancer-controller)가 관리한다."
  type        = bool
  default     = true
}

# [WHY — chart_version/role_name을 각각 변수로 안 두고 객체 통째로 받는 이유]
# role_name 하나만 변수로 빼는 방식도 가능하지만, 그러면 "이 addon 설정 중 어디까지가 root
# 책임이고 어디부터가 모듈 책임인가"의 경계가 애매해진다. aws-ia/eks-blueprints-addons가
# 받는 aws_load_balancer_controller 객체 전체(chart_version, role_name,
# role_name_use_prefix 등)를 이 모듈은 내용을 전혀 들여다보지 않고 그대로 vendor에
# 전달한다 — enable_aws_load_balancer_controller(켜고 끄기)만 이 모듈이 알고, 나머지는 전부
# root가 결정한다(재사용 가능한 Terraform 모듈에서 흔히 쓰는 패턴:
# `aws_load_balancer_controller = try(each.value.aws_load_balancer_controller, ...)`
# 형태로 addon 설정 객체를 그대로 pass-through). 기본값이 없는 이유도 같다 — 네이밍 정책이
# 바뀌어도 이 공유 모듈은 절대 안 건드리고 root 값만 바꾸면 되게 하기 위함이다.
variable "lbc_config" {
  description = "aws-ia/eks-blueprints-addons의 aws_load_balancer_controller 객체를 그대로 전달한다(chart_version/role_name/role_name_use_prefix 등). 이 모듈은 내용을 모른다 — 전부 호출자가 결정"
  type        = any
}

variable "enable_external_dns" {
  description = "ExternalDNS 설치 여부. false이면 blueprints가 관련 IAM Role과 Helm release를 생성하지 않는다"
  type        = bool
  default     = true
}

variable "external_dns_route53_zone_arns" {
  description = "ExternalDNS가 레코드를 관리할 Route53 Hosted Zone ARN 목록. 빈 리스트이면 모든 Hosted Zone 접근 허용 (운영 환경에서는 반드시 명시할 것)"
  type        = list(string)
  default     = []
}

# 기본값 없음 — lbc_config와 동일한 이유(위 참고).
variable "external_dns_config" {
  description = "aws-ia/eks-blueprints-addons의 external_dns 객체를 그대로 전달한다(chart_version/role_name 등). 이 모듈은 내용을 모른다 — 전부 호출자가 결정"
  type        = any
}

variable "enable_external_secrets" {
  description = "External Secrets Operator 설치 여부"
  type        = bool
  default     = false # 신규 애드온이므로 opt-in (enable_otel_spoke_collector와 동일한 정책)
}

# 기본값 없음 — lbc_config와 동일한 이유(위 참고). validation은 nested key(chart_version)를
# try()로 방어적으로 확인한다 — type=any라 존재하지 않는 키 접근은 plan 단계에서 에러가 나므로.
variable "external_secrets_config" {
  description = "aws-ia/eks-blueprints-addons의 external_secrets 객체를 그대로 전달한다(chart_version/role_name 등). 이 모듈은 내용을 모른다 — 전부 호출자가 결정"
  type        = any

  validation {
    condition     = !var.enable_external_secrets || (try(var.external_secrets_config.chart_version, null) != null && length(var.external_secrets_config.chart_version) > 0)
    error_message = "enable_external_secrets=true일 때 external_secrets_config.chart_version은 설정되어야 합니다."
  }
}

variable "external_secrets_ssm_parameter_arns" {
  description = "External Secrets Operator가 읽을 수 있는 SSM Parameter ARN 목록. 빈 리스트이면 blueprints 기본값(모든 파라미터 와일드카드 arn:aws:ssm:*:*:parameter/*)을 사용 — 운영 환경에서는 반드시 명시할 것"
  type        = list(string)
  default     = []
}

variable "external_secrets_kms_key_arns" {
  description = "External Secrets Operator가 SecureString 파라미터 복호화에 사용할 KMS Key ARN 목록. 빈 리스트이면 blueprints 기본값(모든 KMS 키 와일드카드 arn:aws:kms:*:*:key/*)을 사용 — 운영 환경에서는 반드시 명시할 것"
  type        = list(string)
  default     = []
}


variable "enable_karpenter" {
  description = "Karpenter 설치 여부. false이면 blueprints가 관련 IAM Role, SQS, EventBridge Rule, Helm release를 생성하지 않는다"
  type        = bool
  default     = true
}

# [WHY — policy_statements는 이 객체 스키마에서 root가 채울 필드가 아니다]
# main.tf에서 이 값을 merge()로 강제 병합한다(iam:CreateServiceLinkedRole — blueprints 기본
# 정책 결함에 대한 정합성 fix, 정책적 선택이 아니라 Karpenter+Spot이 정상 동작하기 위한
# 고정 요구사항). root가 이 필드를 깜빡해도 항상 포함되도록 모듈이 강제한다 — root가
# 추가 정책을 더 넣고 싶으면 이 객체에 policy_statements를 포함해도 되고(모듈이 concat으로
# 합침), 안 넣어도 무방하다.
variable "karpenter_config" {
  description = "aws-ia/eks-blueprints-addons의 karpenter 객체를 그대로 전달한다(chart_version/role_name/policy_name 등). policy_statements는 이 모듈이 정합성 fix를 강제 병합하므로 root가 안 채워도 된다"
  type        = any
}

variable "karpenter_node_config" {
  description = "aws-ia/eks-blueprints-addons의 karpenter_node 객체를 그대로 전달한다(iam_role_name 등). 이 모듈은 내용을 모른다 — 전부 호출자가 결정"
  type        = any
}

variable "karpenter_sqs_config" {
  description = "aws-ia/eks-blueprints-addons의 karpenter_sqs 객체를 그대로 전달한다(queue_name). 이 모듈은 내용을 모른다 — 전부 호출자가 결정"
  type        = any
}

variable "enable_argocd" {
  description = "ArgoCD 설치 여부 (GitOps 전환 Phase 5)"
  type        = bool
  default     = true
}

# [WHY — Argo Rollouts는 이 모듈이 전혀 관여하지 않는데 이 변수가 왜 필요한가]
# Argo Rollouts는 처음부터 ArgoCD가 Helm으로 설치·관리한다(devops-manifest) — Terraform은
# IAM도 Helm도 관여하지 않는다. 하지만 ArgoCD 자신의 UI에는 Argo Rollouts 진행 상황을 보여주는
# rollout-extension이 있고, 그건 ArgoCD Helm values(이 모듈이 관리)의 일부라서 "Argo Rollouts가
# 클러스터에 실제로 있는가"를 이 모듈에 알려줘야 한다. 이 모듈은 그걸 스스로 알 방법이 없으므로
# (Argo Rollouts에 전혀 관여하지 않으니) root가 직접 알려준다 — 기본값을 두지 않는 이유도
# 다른 *_config 변수와 동일: false로 잘못 추정했다가 UI extension이 조용히 꺼지는 것보다,
# root가 명시적으로 결정하게 강제하는 편이 안전하다.
variable "argo_rollouts_extension_enabled" {
  description = "ArgoCD UI의 Argo Rollouts rollout-extension 활성화 여부. Argo Rollouts가 클러스터에 실제로 존재하는지는 이 모듈이 알 수 없으므로 root가 직접 결정한다"
  type        = bool
}

variable "argocd_notifications_slack_enabled" {
  description = "ArgoCD Application Notifications의 Slack 알림 서비스 활성화 여부. true로 설정하는 환경은 argocd 네임스페이스에 argocd-notifications-secret Secret(키 slack-token)이 미리 준비되어 있어야 한다(예: External Secrets Operator). true가 되면 ArgoCD 차트의 notifications 서브컴포넌트(별도 컨트롤러 파드)가 함께 활성화된다."
  type        = bool
  default     = false
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart 버전 (예: \"9.5.21\")"
  type        = string
}

variable "argocd_ha_enabled" {
  description = "ArgoCD HA 모드. true면 redis-ha 활성화 + server/repoServer/applicationSet replica를 replica_counts.argocd_server로 증설. false면 모든 컴포넌트 단일 replica, redis-ha 비활성"
  type        = bool
  default     = false
}

variable "argocd_ingress_enabled" {
  description = "ArgoCD server에 ALB Ingress(외부 접근)를 구성할지 여부. true면 server.insecure=true로 전환되어 ALB가 TLS를 종료한다"
  type        = bool
  default     = false
}

variable "argocd_ingress_hostname" {
  description = "ArgoCD server Ingress의 호스트명 (예: \"argo-develop.pyhtest.com\"). argocd_ingress_enabled=true일 때 필수"
  type        = string
  default     = ""

  validation {
    condition     = !var.argocd_ingress_enabled || length(var.argocd_ingress_hostname) > 0
    error_message = "argocd_ingress_enabled=true일 때 argocd_ingress_hostname은 빈 문자열일 수 없습니다."
  }
}

variable "argocd_ingress_acm_certificate_arn" {
  description = "ArgoCD ALB Ingress가 사용할 ACM 인증서 ARN. argocd_ingress_enabled=true일 때 필수"
  type        = string
  default     = ""

  validation {
    condition     = !var.argocd_ingress_enabled || can(regex("^arn:aws:acm:", var.argocd_ingress_acm_certificate_arn))
    error_message = "argocd_ingress_enabled=true일 때 argocd_ingress_acm_certificate_arn은 유효한 ACM 인증서 ARN이어야 합니다."
  }
}

variable "argocd_ingress_allowed_cidrs" {
  description = "ArgoCD ALB Ingress 접근을 허용할 CIDR 목록 (ALB Security Group inbound 규칙). argocd_ingress_enabled=true일 때 필수 — dex 비활성화 상태에서 기본 admin 계정만으로 인증하므로 접근 IP를 제한한다"
  type        = list(string)
  default     = []

  validation {
    # 빈 리스트면 join(",", [])="" → ALB inbound-cidrs 어노테이션이 무효화되어 0.0.0.0/0(전체 허용)으로
    # fail-open될 수 있다. argocd_ingress_enabled=true일 때는 반드시 1개 이상의 유효한 CIDR을 강제한다.
    condition = !var.argocd_ingress_enabled || (
      length(var.argocd_ingress_allowed_cidrs) > 0 &&
      alltrue([for cidr in var.argocd_ingress_allowed_cidrs : can(cidrnetmask(cidr))])
    )
    error_message = "argocd_ingress_enabled=true일 때 argocd_ingress_allowed_cidrs는 최소 1개 이상의 유효한 CIDR(예: 1.2.3.4/32)을 포함해야 합니다. 비워두거나 형식이 잘못된 값이 있으면 ALB가 모든 IP를 허용할 수 있습니다."
  }
}

variable "argocd_ingress_alb_name" {
  description = "ArgoCD server ALB Ingress의 ALB 이름 (alb.ingress.kubernetes.io/load-balancer-name). argocd_ingress_enabled=true일 때 필수. AWS ALB 이름 제한(최대 32자, 영문/숫자/하이픈)을 따라야 한다"
  type        = string
  default     = ""

  validation {
    condition     = !var.argocd_ingress_enabled || length(var.argocd_ingress_alb_name) > 0
    error_message = "argocd_ingress_enabled=true일 때 argocd_ingress_alb_name은 빈 문자열일 수 없습니다."
  }

  validation {
    # AWS ALB 이름 제한: 최대 32자, 영문/숫자/하이픈만 허용, 하이픈으로 시작/종료 불가
    # 1자 이름(영문/숫자 단독)도 허용: `([a-zA-Z0-9-]{0,30}[a-zA-Z0-9])?`로 감싸 선택적 처리
    condition     = var.argocd_ingress_alb_name == "" || can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]{0,30}[a-zA-Z0-9])?$", var.argocd_ingress_alb_name))
    error_message = "argocd_ingress_alb_name은 1~32자의 영문/숫자/하이픈만 허용하며 하이픈으로 시작하거나 끝날 수 없습니다."
  }
}

variable "argocd_admin_password_bcrypt" {
  description = "ArgoCD admin 초기 패스워드의 bcrypt 해시. 설정하면 Helm 배포 시 argocd-secret에 주입된다. 비워두면 ArgoCD가 자동 생성한 시크릿을 사용하고 'argocd-initial-admin-secret'에서 확인해야 한다. 해시 생성: python3 -c \"import bcrypt; print(bcrypt.hashpw(b'PASSWORD', bcrypt.gensalt()).decode())\". 반드시 argocd_admin_password_mtime과 함께 설정한다"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.argocd_admin_password_bcrypt == "" || can(regex("^\\$2[aby]\\$", var.argocd_admin_password_bcrypt))
    error_message = "argocd_admin_password_bcrypt는 bcrypt 해시 형식($2a$, $2b$, $2y$ 접두사)이어야 합니다. Terraform bcrypt() 함수가 아닌 사전 계산된 해시를 사용하세요."
  }
}

variable "argocd_admin_password_mtime" {
  description = "argocd_admin_password_bcrypt와 짝을 이루는 타임스탬프 (RFC3339). ArgoCD가 이 값으로 패스워드 변경 여부를 판단하므로 패스워드 변경 시 반드시 함께 갱신해야 한다. 예: \"2026-06-16T00:00:00Z\""
  type        = string
  default     = ""
}

# lbc/karpenter/external_dns/metrics_server/argo_rollouts/external_secrets 필드는 없다 —
# 그 addon들의 Helm release는 ArgoCD가 관리해서 replica 수도 devops-manifest의
# values-override.yaml이 결정한다. 이 모듈이 Helm을 직접 만드는 건 ArgoCD 자신뿐이라
# argocd_server만 의미가 있다.
variable "replica_counts" {
  description = "ArgoCD server/repoServer/applicationSet의 HA 모드 replica 수"
  type = object({
    argocd_server = optional(number, 2) # ArgoCD HA 모드에서 server/repoServer/applicationSet replica 수
  })
  default = {}

  validation {
    condition     = alltrue([for v in values(var.replica_counts) : v >= 1])
    error_message = "replica_counts의 모든 값은 1 이상이어야 합니다. 0으로 설정하면 해당 애드온 Pod가 생성되지 않습니다."
  }
}

variable "additional_tags" {
  description = "모든 리소스에 추가할 태그 맵. providers.tf의 default_tags로 공통 태그를 관리하므로, 이 변수는 호출자가 추가로 전달할 태그에만 사용한다"
  type        = map(string)
  default     = {}
}

# ── OTel Spoke Collector ──────────────────────────────────────────────────────

variable "enable_otel_spoke_collector" {
  description = "OTel spoke collector 설치 여부. true로 설정하면 OTel Operator와 DaemonSet·Deployment 수집기를 otel-collector 네임스페이스에 배포한다. otel_gateway_endpoint와 otel_spoke_operator_chart_version을 함께 설정해야 한다"
  type        = bool
  default     = false
}

variable "otel_gateway_endpoint" {
  description = "monitoring 클러스터 OTel Gateway Internal NLB 엔드포인트 (예: 'internal-xxxx.elb.ap-northeast-2.amazonaws.com:4317'). enable_otel_spoke_collector=true일 때 필수"
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_otel_spoke_collector || length(var.otel_gateway_endpoint) > 0
    error_message = "enable_otel_spoke_collector=true일 때 otel_gateway_endpoint는 비어 있을 수 없습니다."
  }
}

variable "otel_spoke_operator_chart_version" {
  description = "OTel Operator Helm chart 버전 (예: '0.76.1'). enable_otel_spoke_collector=true일 때 필수"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.enable_otel_spoke_collector || (var.otel_spoke_operator_chart_version != null && length(var.otel_spoke_operator_chart_version) > 0)
    error_message = "enable_otel_spoke_collector=true일 때 otel_spoke_operator_chart_version은 설정되어야 합니다."
  }
}

variable "external_dns_assume_role_arn" {
  description = "ExternalDNS가 크로스 계정 Route53을 관리하기 위해 assume할 IAM Role ARN. 비어있으면 동일 계정 Route53 직접 접근 (dev/prd 기본값). monitoring처럼 Route53이 다른 계정에 있을 때 설정한다"
  type        = string
  default     = ""

  validation {
    condition     = var.external_dns_assume_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.external_dns_assume_role_arn))
    error_message = "external_dns_assume_role_arn은 빈 문자열이거나 유효한 IAM Role ARN(arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME) 형식이어야 합니다."
  }
}

variable "argocd_controller_irsa_role_arn" {
  description = "ArgoCD application-controller ServiceAccount(argocd-application-controller)에 붙일 IRSA Role ARN. GitOps Bridge 패턴에서 ArgoCD가 다른/자기 자신 클러스터를 awsAuthConfig로 명시 등록할 때 필요. null이면 이 값을 주입하지 않는다(기존 in-cluster 암묵 등록만 쓰는 환경은 불필요)."
  type        = string
  nullable    = true
  default     = null
}

# [WHY — Hub 여부를 코드 위치가 아니라 변수의 null 여부로 가르는 이유]
# 여러 클러스터를 관리하는 실무 Terraform 모듈에서 흔히 쓰는 opt-in 패턴을 따른다(예:
# 공용 EKS 모듈이 Hub 전용 부트스트랩 서브모듈을 for_each 키의 존재 여부로 opt-in시키는
# 구조). "코드가 어디 있는가"와 "이 클러스터가 Hub인가"는 별개 문제다 — Hub만 갖는
# 데이터(image-updater Role ARN 등)는 root에서 계산해 변수로 넘기면 그만이고, "Hub냐
# 아니냐"라는 판단 자체는 이 변수 하나(null이면 spoke, 값이 있으면 Hub)로 표현하는 게
# 재사용성 측면에서 낫다. develop/production이 이 모듈(2.0.0)로 이관되어 spoke가 되어도,
# 이 변수를 안 넘기기만 하면 코드 수정 없이 자연스럽게 spoke로 동작한다.
variable "gitops_bridge_hub" {
  description = "GitOps Bridge Hub 전용 설정(cluster/apps). null이면 이 클러스터는 Hub 역할을 하지 않는다 — module.gitops_bridge_bootstrap의 cluster Secret·App-of-Apps 리소스가 생성되지 않는다. 스키마는 gitops-bridge-dev/gitops-bridge/helm 모듈 자체의 cluster/apps 변수를 그대로 따른다(별도 스키마를 새로 정의하지 않음 — 벤더 모듈의 인터페이스를 그대로 노출)."
  type        = any
  nullable    = true
  default     = null
}
