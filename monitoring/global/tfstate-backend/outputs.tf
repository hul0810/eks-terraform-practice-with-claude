output "bucket_name" {
  description = "Terraform state S3 버킷 이름"
  value       = aws_s3_bucket.tfstate.bucket
}
