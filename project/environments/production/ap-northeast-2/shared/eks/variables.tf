variable "account_id_mgmt" {
  type        = string
  description = "관리 계정 AWS 계정 ID. secret.auto.tfvars에서 설정"
}

variable "operator_ip_cidr" {
  type        = string
  description = "운영자 공인 IP CIDR (예: x.x.x.x/32). EKS 퍼블릭 엔드포인트 접근 허용 IP"
}
