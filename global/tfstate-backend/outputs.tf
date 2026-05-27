output "s3_bucket_name" {
  description = "Terraform 상태 파일 저장 S3 버킷명"
  value       = aws_s3_bucket.tfstate.id
}

output "s3_bucket_arn" {
  description = "Terraform 상태 파일 저장 S3 버킷 ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_table_name" {
  description = "Terraform 상태 잠금 DynamoDB 테이블명"
  value       = aws_dynamodb_table.tfstate_lock.id
}
