resource "aws_s3_bucket" "this" {
  for_each = local.backends

  bucket = each.value.bucket_name
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.backends

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.backends

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3(AES256) — SSE-KMS는 API 호출 건당 과금(GenerateDataKey)이 추가되는데, Loki/Mimir/
      # Tempo는 청크를 매우 잦은 빈도로 쓰고 읽어 이 건수 과금이 누적되면 저장 비용보다 커질 수
      # 있다. 관측성 스토리지는 규정 준수상 CMK가 필요한 데이터가 아니라 SSE-S3로 충분하다.
      sse_algorithm = "AES256"
    }
  }
}

# 버저닝을 명시적으로 "Disabled"로 선언한다(AWS S3 API 자체는 미버전화 상태로 되돌리는 값을
# 지원하지 않지만, provider가 "Disabled"를 별도 처리해 PutBucketVersioning 호출 없이 미버전화
# 상태를 그대로 유지한다 — terraform-provider-aws v6.57.1 소스 확인:
# internal/service/s3/bucket_versioning.go의 status != "Disabled"일 때만 API를 호출).
# 버저닝을 켜지 않는 이유: Loki/Mimir/Tempo 모두 compactor가 객체를 지속적으로 재작성·삭제하는데,
# 버저닝 상태면 삭제된 이전 버전이 계속 남아 과금되고 조회 대상도 아니다.
resource "aws_s3_bucket_versioning" "this" {
  for_each = local.backends

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.backends

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    # 버킷 전체 대상 — filter/prefix를 모두 생략해도 provider가 빈 필터를 자동 전송하지만
    # (terraform-provider-aws v6.57.1 확인: filter가 null이면 빈 LifecycleRuleFilter{}를 채움),
    # "전체 버킷 대상"이라는 의도를 코드에서 명시하기 위해 빈 filter 블록을 그대로 둔다.
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # 보존기간(객체 만료) 규칙은 넣지 않는다 — 보존은 각 제품의 compactor가 자체 정책으로
    # 관리한다. S3 라이프사이클로 별도 만료 규칙을 추가하면 제품 인덱스가 아는 객체 존재 여부와
    # 실제 S3 객체 존재 여부가 어긋나 조회가 깨진다. 어떤 제품도 청소하지 않는 중단된 멀티파트
    # 업로드만 이 규칙으로 정리한다.
  }
}
