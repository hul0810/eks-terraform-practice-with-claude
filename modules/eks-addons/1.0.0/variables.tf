################################################################################
# EKS Addons 모듈 입력 변수
################################################################################

variable "cluster_name" {
  description = "EKS 클러스터 이름. IAM Role 이름 조합에도 사용된다 ({cluster_name}-{addon})"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트 URL. eks-blueprints-addons 모듈의 필수 입력값"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes 버전 (예: \"1.33\"). eks-blueprints-addons 모듈의 Helm chart 호환성 확인에 사용"
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version은 \"1.XX\" 형식이어야 합니다 (예: \"1.33\")."
  }
}

variable "oidc_provider_arn" {
  description = "IRSA용 OIDC Provider ARN. eks-blueprints-addons 모듈이 LBC IAM Role 생성에 사용한다. 기본 전략은 Pod Identity이나 Blueprints 모듈 내부 IRSA 구현으로 LBC를 관리한다"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/", var.oidc_provider_arn))
    error_message = "oidc_provider_arn은 유효한 OIDC Provider ARN이어야 합니다."
  }
}

variable "addon_versions" {
  description = "EKS 관리형 애드온 버전 맵. most_recent 사용 금지 — 버전을 명시해야 환경 간 일관성이 보장된다"
  type = object({
    ebs_csi_driver = string
    metrics_server = string
    external_dns   = string
  })
}

variable "enable_external_dns" {
  description = "External DNS 애드온 설치 여부. false이면 관련 IAM Role, Pod Identity Association, EKS Addon이 모두 생성되지 않는다"
  type        = bool
  default     = true
}

variable "lbc_chart_version" {
  description = "AWS Load Balancer Controller Helm chart 버전 (예: \"3.4.0\"). eks-blueprints-addons 모듈에 전달된다"
  type        = string
}

variable "additional_tags" {
  description = "모든 리소스에 추가할 태그 맵. providers.tf의 default_tags로 공통 태그를 관리하므로, 이 변수는 모듈 호출자가 추가로 전달할 태그에만 사용한다"
  type        = map(string)
  default     = {}
}
