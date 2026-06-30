variable "operator_ip_cidr" {
  type        = string
  description = "운영자 공인 IP CIDR (예: x.x.x.x/32). ArgoCD ALB SG inbound 허용 IP"
}

variable "argocd_admin_password_bcrypt" {
  type        = string
  sensitive   = true
  description = "ArgoCD admin 초기 패스워드 bcrypt 해시. python3 -c \"import bcrypt; print(bcrypt.hashpw(b'PASS', bcrypt.gensalt()).decode())\""
}
