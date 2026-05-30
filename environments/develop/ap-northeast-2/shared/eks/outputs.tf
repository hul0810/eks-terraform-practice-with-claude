output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
  sensitive   = false
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트 URL"
  value       = module.eks.cluster_endpoint
  sensitive   = false
}

output "cluster_certificate_authority_data" {
  description = "클러스터 CA 인증서 데이터 (Base64 인코딩)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

# Phase 2-3 Karpenter IAM Role 생성 시 필요
output "oidc_provider_arn" {
  description = "IRSA용 OIDC Provider ARN (Karpenter, LBC, EBS CSI Driver IAM Role 생성에 사용)"
  value       = module.eks.oidc_provider_arn
  sensitive   = false
}

output "cluster_security_group_id" {
  description = "EKS 클러스터 Security Group ID"
  value       = module.eks.cluster_security_group_id
  sensitive   = false
}

output "node_security_group_id" {
  description = "노드 그룹 공유 Security Group ID"
  value       = module.eks.node_security_group_id
  sensitive   = false
}
