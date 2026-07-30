output "bucket_names" {
  description = "백엔드별(loki/mimir/tempo) S3 버킷 이름 맵"
  value       = { for k, v in aws_s3_bucket.this : k => v.bucket }
}

output "bucket_arns" {
  description = "백엔드별(loki/mimir/tempo) S3 버킷 ARN 맵"
  value       = { for k, v in aws_s3_bucket.this : k => v.arn }
}

output "role_arns" {
  description = "백엔드별(loki/mimir/tempo) Pod Identity IAM Role ARN 맵 — Helm values의 serviceAccount 어노테이션 참고용이 아니라 GitOps Bridge 메타데이터 전달 등에 사용"
  value       = { for k, v in aws_iam_role.this : k => v.arn }
}

output "pod_identity_association_ids" {
  description = "백엔드별(loki/mimir/tempo) EKS Pod Identity Association ID 맵"
  value       = { for k, v in aws_eks_pod_identity_association.this : k => v.association_id }
}
