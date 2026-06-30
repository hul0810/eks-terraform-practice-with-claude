variable "account_id_mgmt" {
  type        = string
  description = "관리 계정 AWS 계정 ID. secret.auto.tfvars에서 설정"
}

variable "account_id_workload" {
  type        = string
  description = "workload 계정 AWS 계정 ID. secret.auto.tfvars에서 설정"
}

variable "account_id_monitoring" {
  type        = string
  description = "monitoring 계정 AWS 계정 ID. secret.auto.tfvars에서 설정"
}
