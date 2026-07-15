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
  description = "EKS 클러스터가 속한 VPC ID. LBC가 VPC ID를 IMDS에서 조회하지 않도록 직접 주입한다"
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id는 \"vpc-\" 접두사로 시작하는 유효한 VPC ID이어야 합니다 (예: \"vpc-0a1b2c3d4e5f67890\")."
  }
}

variable "enable_aws_load_balancer_controller" {
  description = "AWS Load Balancer Controller 설치 여부"
  type        = bool
  default     = true
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart 버전 (예: \"3.4.0\")"
  type        = string
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

variable "external_dns_chart_version" {
  description = "ExternalDNS Helm chart 버전 (예: \"1.14.5\")"
  type        = string
}

variable "enable_metrics_server" {
  description = "Metrics Server 설치 여부"
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "Metrics Server Helm chart 버전 (예: \"3.12.2\")"
  type        = string
}

variable "enable_external_secrets" {
  description = "External Secrets Operator 설치 여부"
  type        = bool
  default     = false # 신규 애드온이므로 opt-in (enable_argo_rollouts, enable_otel_spoke_collector와 동일한 정책)
}

variable "external_secrets_chart_version" {
  description = "External Secrets Operator Helm chart 버전 (예: \"2.7.0\"). enable_external_secrets=false이면 미사용 — null 허용"
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = !var.enable_external_secrets || (var.external_secrets_chart_version != null && length(var.external_secrets_chart_version) > 0)
    error_message = "enable_external_secrets=true일 때 external_secrets_chart_version은 설정되어야 합니다."
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

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart 버전 (예: \"1.3.3\")"
  type        = string
}

variable "enable_argocd" {
  description = "ArgoCD 설치 여부 (GitOps 전환 Phase 5)"
  type        = bool
  default     = true
}

variable "enable_argo_rollouts" {
  description = "Argo Rollouts 설치 여부. Canary·Blue-Green 배포 전략을 Kubernetes에서 구현한다"
  type        = bool
  default     = false
}

variable "argo_rollouts_chart_version" {
  description = "Argo Rollouts Helm chart 버전 (예: \"2.38.1\"). enable_argo_rollouts=false이면 미사용 — null 허용"
  type        = string
  nullable    = true
  default     = null
}

variable "argo_rollouts_notifications_slack_enabled" {
  description = "Argo Rollouts Notifications의 Slack 알림 서비스(notifications.notifiers[\"service.slack\"]) 활성화 여부. true로 설정하는 환경은 대상 네임스페이스(argo-rollouts)에 argo-rollouts-notification-secret Secret(키 slack-token)이 미리 준비되어 있어야 한다(예: External Secrets Operator)."
  type        = bool
  default     = false
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

variable "replica_counts" {
  description = "애드온별 Pod replica 수. 환경별로 HA/비용 요구사항에 맞게 조정한다. 기본값은 프로덕션 권장 최솟값"
  type = object({
    lbc              = optional(number, 2) # LBC: replicaCount 기본 2
    karpenter        = optional(number, 2) # Karpenter: replicas 기본 2
    external_dns     = optional(number, 1) # ExternalDNS: 기본 1 (단일 인스턴스로 충분)
    metrics_server   = optional(number, 1) # MetricsServer: replicas 기본 1
    argocd_server    = optional(number, 2) # ArgoCD HA 모드에서 server/repoServer/applicationSet replica 수
    argo_rollouts    = optional(number, 1) # Argo Rollouts controller: 기본 1. 시스템 노드 HA(min>=2) 확보 후 2로 증설
    external_secrets = optional(number, 1) # External Secrets Operator: replicaCount 기본 1
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
