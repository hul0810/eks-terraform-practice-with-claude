# terraform-aws-modules/ecr는 리포지토리당 하나의 모듈 인스턴스를 생성하는 구조.
# for_each로 map key를 stable address로 사용하여 리포지토리 추가/삭제 시 무관한 리소스 재생성을 방지한다.
module "repositories" {
  source   = "terraform-aws-modules/ecr/aws"
  version  = "~> 3.2.0"
  for_each = var.repositories

  repository_name                   = each.key
  repository_image_tag_mutability   = each.value.image_tag_mutability
  repository_image_scan_on_push     = each.value.scan_on_push
  repository_encryption_type        = each.value.encryption_type
  repository_force_delete           = each.value.force_delete
  repository_read_access_arns       = each.value.read_access_arns
  repository_read_write_access_arns = each.value.read_write_access_arns

  # attach_repository_policy: read/write ARN이 하나라도 있을 때만 정책 생성.
  # 비어 있으면 빈 정책 문서로 apply 오류가 발생하므로 조건부 활성화한다.
  attach_repository_policy = length(each.value.read_access_arns) > 0 || length(each.value.read_write_access_arns) > 0

  create_lifecycle_policy = true

  # 두 규칙의 우선순위: 태그 없는 이미지 만료(1) → 전체 이미지 수 제한(2).
  # 순서가 바뀌면 untagged 이미지가 count 제한에 먼저 걸려 의도치 않게 tagged 이미지가 삭제될 수 있다.
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "태그 없는 이미지 ${each.value.lifecycle_untagged_days}일 후 삭제"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = each.value.lifecycle_untagged_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "태그된 이미지 최신 ${each.value.lifecycle_tagged_count}개만 유지"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = each.value.lifecycle_tagged_count
        }
        action = { type = "expire" }
      }
    ]
  })
}
