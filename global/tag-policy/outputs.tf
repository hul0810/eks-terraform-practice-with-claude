locals {
  _policy = jsondecode(aws_organizations_policy.required_tags.content)
}

output "allowed_environments" {
  description = "environment 태그 허용값 목록. validate_tags precondition의 단일 소스."
  value       = local._policy.tags.environment.tag_value["@@assign"]
}

output "allowed_managed_by" {
  description = "managed_by 태그 허용값 목록. validate_tags precondition의 단일 소스."
  value       = local._policy.tags.managed_by.tag_value["@@assign"]
}
