<!-- BEGIN_TF_DOCS -->
<!-- 이 파일은 terraform-docs가 자동 생성합니다. 직접 수정하지 마세요. -->
<!-- 설계 결정과 WHY는 같은 디렉토리의 CLAUDE.md를 참조하세요. -->

## Requirements

No requirements.

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_repositories"></a> [repositories](#module\_repositories) | terraform-aws-modules/ecr/aws | ~> 3.2.0 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_repositories"></a> [repositories](#input\_repositories) | 생성할 ECR 리포지토리 설정 맵. key는 완전한 리포지토리 이름({project}-{service}-{environment} 패턴 권장) | <pre>map(object({<br/>    image_tag_mutability    = optional(string, "IMMUTABLE")<br/>    scan_on_push            = optional(bool, true)<br/>    encryption_type         = optional(string, "AES256")<br/>    lifecycle_untagged_days = optional(number, 14)<br/>    lifecycle_tagged_count  = optional(number, 10)<br/>    force_delete            = optional(bool, false)<br/>    read_access_arns        = optional(list(string), [])<br/>    read_write_access_arns  = optional(list(string), [])<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | ECR 레지스트리 ID (AWS 계정 ID와 동일) |
| <a name="output_repository_arns"></a> [repository\_arns](#output\_repository\_arns) | 리포지토리 이름 → ARN 맵 (IAM 정책 Resource 지정 시 사용) |
| <a name="output_repository_urls"></a> [repository\_urls](#output\_repository\_urls) | 리포지토리 이름 → URL 맵 (docker push/pull 시 사용) |
<!-- END_TF_DOCS -->