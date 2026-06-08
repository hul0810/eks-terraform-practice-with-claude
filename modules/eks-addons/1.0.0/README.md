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
| <a name="module_eks_blueprints_addons"></a> [eks\_blueprints\_addons](#module\_eks\_blueprints\_addons) | aws-ia/eks-blueprints-addons/aws | ~> 1.23.0 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_tags"></a> [additional\_tags](#input\_additional\_tags) | 모든 리소스에 추가할 태그 맵. providers.tf의 default\_tags로 공통 태그를 관리하므로, 이 변수는 호출자가 추가로 전달할 태그에만 사용한다 | `map(string)` | `{}` | no |
| <a name="input_cluster_endpoint"></a> [cluster\_endpoint](#input\_cluster\_endpoint) | EKS API 서버 엔드포인트 URL. eks-blueprints-addons 모듈의 필수 입력값 | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS 클러스터 이름. eks-blueprints-addons 모듈의 필수 입력값 | `string` | n/a | yes |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes 버전 (예: "1.33"). eks-blueprints-addons의 Helm chart 호환성 확인에 사용 | `string` | n/a | yes |
| <a name="input_enable_aws_load_balancer_controller"></a> [enable\_aws\_load\_balancer\_controller](#input\_enable\_aws\_load\_balancer\_controller) | AWS Load Balancer Controller 설치 여부 | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | ExternalDNS 설치 여부. false이면 blueprints가 관련 IAM Role과 Helm release를 생성하지 않는다 | `bool` | `true` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Karpenter 설치 여부. false이면 blueprints가 관련 IAM Role, SQS, EventBridge Rule, Helm release를 생성하지 않는다 | `bool` | `true` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Metrics Server 설치 여부 | `bool` | `true` | no |
| <a name="input_external_dns_chart_version"></a> [external\_dns\_chart\_version](#input\_external\_dns\_chart\_version) | ExternalDNS Helm chart 버전 (예: "1.14.5") | `string` | n/a | yes |
| <a name="input_external_dns_route53_zone_arns"></a> [external\_dns\_route53\_zone\_arns](#input\_external\_dns\_route53\_zone\_arns) | ExternalDNS가 레코드를 관리할 Route53 Hosted Zone ARN 목록. 빈 리스트이면 모든 Hosted Zone 접근 허용 (운영 환경에서는 반드시 명시할 것) | `list(string)` | `[]` | no |
| <a name="input_karpenter_chart_version"></a> [karpenter\_chart\_version](#input\_karpenter\_chart\_version) | Karpenter Helm chart 버전 (예: "1.3.3") | `string` | n/a | yes |
| <a name="input_lbc_chart_version"></a> [lbc\_chart\_version](#input\_lbc\_chart\_version) | AWS Load Balancer Controller Helm chart 버전 (예: "3.4.0") | `string` | n/a | yes |
| <a name="input_metrics_server_chart_version"></a> [metrics\_server\_chart\_version](#input\_metrics\_server\_chart\_version) | Metrics Server Helm chart 버전 (예: "3.12.2") | `string` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | IRSA용 OIDC Provider ARN. blueprints 모듈이 LBC·ExternalDNS·Karpenter IAM Role 생성에 사용한다 | `string` | n/a | yes |
| <a name="input_replica_counts"></a> [replica\_counts](#input\_replica\_counts) | 애드온별 Pod replica 수. 환경별로 HA/비용 요구사항에 맞게 조정한다. 기본값은 프로덕션 권장 최솟값 | <pre>object({<br/>    lbc            = optional(number, 2) # LBC: replicaCount 기본 2<br/>    karpenter      = optional(number, 2) # Karpenter: replicas 기본 2<br/>    external_dns   = optional(number, 1) # ExternalDNS: 기본 1 (단일 인스턴스로 충분)<br/>    metrics_server = optional(number, 1) # MetricsServer: replicas 기본 1<br/>  })</pre> | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | EKS 클러스터가 속한 VPC ID. LBC가 VPC ID를 IMDS에서 조회하지 않도록 직접 주입한다 | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | Karpenter 컨트롤러 IRSA IAM Role ARN. blueprints가 생성한다 |
| <a name="output_lbc_role_arn"></a> [lbc\_role\_arn](#output\_lbc\_role\_arn) | AWS Load Balancer Controller IRSA IAM Role ARN. blueprints가 생성한다 |
<!-- END_TF_DOCS -->