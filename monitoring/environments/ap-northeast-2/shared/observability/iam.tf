# 버킷별로 Role을 분리한다 — 한 컴포넌트(예: Tempo)가 침해당해도 다른 백엔드(Loki/Mimir)의
# 데이터에는 닿지 못하게 하기 위함. 네이밍은 modules/eks의 Pod Identity Role과 동일한
# `{cluster_name}-{addon}-pod-id` 컨벤션을 따른다(modules/eks/1.0.0/CLAUDE.md 참조).
resource "aws_iam_role" "this" {
  for_each = local.backends

  name        = "${local.cluster_name}-${each.key}-pod-id"
  description = "${title(each.key)} Pod Identity IAM Role - ${local.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        # TagSession 누락 시 AssumeRole 자체가 실패한다(Pod Identity 신뢰정책 필수 조합).
        Action = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  # name 변경은 IAM ForceNew라 destroy+recreate가 강제된다. CBD 없이 진행하면 구 Role이
  # 삭제된 시점과 pod-identity.tf의 association.role_arn이 신규 ARN으로 갱신되는 시점 사이에
  # association이 이미 삭제된 Role을 가리키는 구간이 생긴다(modules/eks의 vpc_cni/ebs_csi
  # Role과 동일한 이유 — modules/eks/1.0.0/main.tf 참조).
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "this" {
  for_each = local.backends

  # name을 생략하면 AWS가 임의 문자열로 자동 생성해 콘솔에서 정책을 식별하기 어렵다.
  name = "${each.key}-s3-access"
  role = aws_iam_role.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BucketLevel"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:GetBucketLocation",
        ]
        Resource  = aws_s3_bucket.this[each.key].arn
        Condition = local.pod_identity_abac_condition[each.key]
      },
      {
        Sid    = "ObjectLevel"
        Effect = "Allow"
        # 멀티파트 3액션(AbortMultipartUpload/ListMultipartUploadParts/PutObject의 파트 업로드)은
        # Loki/Mimir의 대용량 청크 업로드에 실제로 쓰인다 — 누락하면 특정 크기 이상의 객체에서만
        # 실패해 원인 파악이 어렵다.
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
        Condition = local.pod_identity_abac_condition[each.key]
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }
}
