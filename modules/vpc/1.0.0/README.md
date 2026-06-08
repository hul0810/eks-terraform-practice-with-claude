<!-- BEGIN_TF_DOCS -->
<!-- 이 파일은 terraform-docs가 자동 생성합니다. 직접 수정하지 마세요. -->
<!-- 설계 결정과 WHY는 같은 디렉토리의 CLAUDE.md를 참조하세요. -->

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.47.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 6.6.1 |

## Resources

| Name | Type |
|------|------|
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [terraform_data.validate_subnet_counts](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_tags"></a> [additional\_tags](#input\_additional\_tags) | VPC 및 VPC Endpoint 리소스에 추가할 태그 맵. 서브넷·라우팅 테이블에는 전파되지 않는다. providers.tf의 default\_tags로 공통 태그(environment, managed\_by)를 관리하므로, 이 변수는 리소스 식별에 필요한 추가 태그에만 사용한다. | `map(string)` | `{}` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | 사용할 가용 영역 목록 | `list(string)` | n/a | yes |
| <a name="input_database_subnets"></a> [database\_subnets](#input\_database\_subnets) | 데이터베이스 서브넷 CIDR 목록 (RDS, ElastiCache용) | `list(string)` | `[]` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | NAT Gateway 생성 여부 | `bool` | `true` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | 프라이빗 서브넷 CIDR 목록 (EKS 노드, Pod IP용) | `list(string)` | `[]` | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | 퍼블릭 서브넷 CIDR 목록 (ALB, NAT GW, Bastion용) | `list(string)` | `[]` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | true: 단일 NAT GW(비용 절감) / false: AZ당 1개(고가용성) | `bool` | `true` | no |
| <a name="input_tgw_subnets"></a> [tgw\_subnets](#input\_tgw\_subnets) | Transit Gateway 어태치먼트용 서브넷 CIDR 목록 (인터넷 라우팅 없음) | `list(string)` | `[]` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | VPC CIDR 블록 | `string` | n/a | yes |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | VPC 이름 | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_database_route_table_ids"></a> [database\_route\_table\_ids](#output\_database\_route\_table\_ids) | 데이터베이스 서브넷 라우팅 테이블 ID 목록 |
| <a name="output_database_subnet_ids"></a> [database\_subnet\_ids](#output\_database\_subnet\_ids) | 데이터베이스 서브넷 ID 목록 |
| <a name="output_nat_public_ips"></a> [nat\_public\_ips](#output\_nat\_public\_ips) | NAT Gateway 퍼블릭 IP 목록 |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | 프라이빗 서브넷 라우팅 테이블 ID 목록 |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | 프라이빗 서브넷 ID 목록 (EKS 노드, Pod IP) |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | 퍼블릭 서브넷 ID 목록 |
| <a name="output_tgw_route_table_ids"></a> [tgw\_route\_table\_ids](#output\_tgw\_route\_table\_ids) | TGW 서브넷 라우팅 테이블 ID 목록 (TGW 도입 시 경로 추가용) |
| <a name="output_tgw_subnet_ids"></a> [tgw\_subnet\_ids](#output\_tgw\_subnet\_ids) | Transit Gateway 어태치먼트용 서브넷 ID 목록 |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | VPC CIDR 블록 |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID |
<!-- END_TF_DOCS -->