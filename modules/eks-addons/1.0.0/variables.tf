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

variable "enable_karpenter" {
  description = "Karpenter 설치 여부. false이면 blueprints가 관련 IAM Role, SQS, EventBridge Rule, Helm release를 생성하지 않는다"
  type        = bool
  default     = true
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart 버전 (예: \"1.3.3\")"
  type        = string
}

variable "replica_counts" {
  description = "애드온별 Pod replica 수. 환경별로 HA/비용 요구사항에 맞게 조정한다. 기본값은 프로덕션 권장 최솟값"
  type = object({
    lbc            = optional(number, 2) # LBC: replicaCount 기본 2
    karpenter      = optional(number, 2) # Karpenter: replicas 기본 2
    external_dns   = optional(number, 1) # ExternalDNS: 기본 1 (단일 인스턴스로 충분)
    metrics_server = optional(number, 1) # MetricsServer: replicas 기본 1
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
