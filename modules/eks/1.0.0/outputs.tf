################################################################################
# EKS 모듈 출력값
#
# 모든 output명은 terraform-aws-modules/eks v21.22.0 outputs.tf 기준으로 확인.
# GitHub: https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.22.0/outputs.tf
################################################################################

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
  sensitive   = false
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트 URL (kubectl, Helm 등에서 사용)"
  value       = module.eks.cluster_endpoint
  sensitive   = false
}

output "cluster_certificate_authority_data" {
  description = "클러스터 통신에 필요한 Base64 인코딩 CA 인증서 데이터 (kubeconfig에 포함됨)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "IRSA용 OIDC Provider ARN. blueprints 모듈(LBC, ExternalDNS, Karpenter)과 EBS CSI IRSA 구성에 사용된다"
  value       = module.eks.oidc_provider_arn
  sensitive   = false
}

output "vpc_cni_role_arn" {
  description = "VPC CNI Pod Identity IAM Role ARN"
  value       = aws_iam_role.vpc_cni.arn
  sensitive   = false
}

output "ebs_csi_role_arn" {
  description = "EBS CSI Driver Pod Identity IAM Role ARN"
  value       = aws_iam_role.ebs_csi.arn
  sensitive   = false
}

output "cluster_security_group_id" {
  description = "EKS가 생성한 클러스터(컨트롤 플레인) Security Group ID"
  value       = module.eks.cluster_security_group_id
  sensitive   = false
}

output "node_security_group_id" {
  description = "노드 그룹 공유 Security Group ID (추가 SG 규칙 연결 시 참조)"
  value       = module.eks.node_security_group_id
  sensitive   = false
}

output "node_role_arn" {
  description = "시스템 노드 그룹 IAM Role ARN. Karpenter가 노드를 aws-auth ConfigMap에 등록할 때 참조한다"
  value       = module.eks.eks_managed_node_groups["system"].iam_role_arn
  sensitive   = false
}
