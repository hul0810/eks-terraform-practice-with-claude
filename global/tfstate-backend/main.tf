data "aws_caller_identity" "current" {}

locals {
  project    = "eks-practice"
  account_id = data.aws_caller_identity.current.account_id

  bucket_name = "${local.project}-tfstate-${local.account_id}"
}

# --------------------------------------------------
# S3 버킷 (Terraform 상태 파일 저장)
# --------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --------------------------------------------------
# S3 버킷 수명 주기 (버전 보관 개수 제한)
# --------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # 버저닝 활성화 이후에 적용되어야 한다
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "limit-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      # 최신 5개 버전만 보관하고 나머지 이전 버전은 만료
      newer_noncurrent_versions = 5
      noncurrent_days           = 1
    }

    # 만료된 객체 삭제 마커 자동 제거 (버전 정리 후 남는 마커 제거)
    expiration {
      expired_object_delete_marker = true
    }
  }
}
