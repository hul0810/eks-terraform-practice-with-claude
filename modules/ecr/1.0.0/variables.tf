variable "repositories" {
  description = "생성할 ECR 리포지토리 설정 맵. key는 완전한 리포지토리 이름({project}-{service}-{environment} 패턴 권장)"
  type = map(object({
    image_tag_mutability    = optional(string, "IMMUTABLE")
    scan_on_push            = optional(bool, true)
    encryption_type         = optional(string, "AES256")
    lifecycle_untagged_days = optional(number, 14)
    lifecycle_tagged_count  = optional(number, 10)
    force_delete            = optional(bool, false)
    read_access_arns        = optional(list(string), [])
    read_write_access_arns  = optional(list(string), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for _, v in var.repositories :
      contains(["MUTABLE", "IMMUTABLE"], v.image_tag_mutability)
    ])
    error_message = "image_tag_mutability는 MUTABLE 또는 IMMUTABLE이어야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.repositories :
      contains(["AES256", "KMS"], v.encryption_type)
    ])
    error_message = "encryption_type은 AES256 또는 KMS여야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.repositories :
      v.lifecycle_untagged_days > 0
    ])
    error_message = "lifecycle_untagged_days는 1 이상이어야 합니다."
  }

  validation {
    condition = alltrue([
      for _, v in var.repositories :
      v.lifecycle_tagged_count > 0
    ])
    error_message = "lifecycle_tagged_count는 1 이상이어야 합니다."
  }
}
