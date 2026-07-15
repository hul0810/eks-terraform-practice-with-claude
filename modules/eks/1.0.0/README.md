<!-- BEGIN_TF_DOCS -->
<!-- 이 파일은 terraform-docs가 자동 생성합니다. 직접 수정하지 마세요. -->
<!-- 설계 결정과 WHY는 같은 디렉토리의 CLAUDE.md를 참조하세요. -->

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.47.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 21.22.0 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.vpc_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_access_entries"></a> [access\_entries](#input\_access\_entries) | EKS Access Entry 목록. IAM 엔티티(User/Role)에 Kubernetes 권한을 부여한다. principal\_arn별로 policy\_associations를 중첩 map으로 선언한다. 클러스터가 재생성되어도 terraform apply 한 번으로 접근 권한이 자동 복원된다. | <pre>map(object({<br/>    principal_arn     = string<br/>    type              = optional(string, "STANDARD")<br/>    kubernetes_groups = optional(list(string))<br/>    user_name         = optional(string)<br/>    tags              = optional(map(string), {})<br/>    policy_associations = optional(map(object({<br/>      policy_arn = string<br/>      access_scope = object({<br/>        namespaces = optional(list(string))<br/>        type       = string<br/>      })<br/>    })), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_additional_tags"></a> [additional\_tags](#input\_additional\_tags) | 모든 리소스에 추가할 태그 맵. providers.tf의 default\_tags로 공통 태그(environment, managed\_by)를 관리하므로, 이 변수는 리소스 식별에 필요한 추가 태그에만 사용한다. | `map(string)` | `{}` | no |
| <a name="input_addon_versions"></a> [addon\_versions](#input\_addon\_versions) | Bootstrap 애드온 버전 맵. most\_recent 사용 금지 — 명시적 버전 고정이 환경 간 일관성을 보장한다 | <pre>object({<br/>    vpc_cni                = string<br/>    kube_proxy             = string<br/>    coredns                = string<br/>    eks_pod_identity_agent = string<br/>    ebs_csi_driver         = string<br/>    cert_manager           = string<br/>  })</pre> | n/a | yes |
| <a name="input_cert_manager_configuration_values"></a> [cert\_manager\_configuration\_values](#input\_cert\_manager\_configuration\_values) | cert-manager EKS 커뮤니티 애드온 configuration\_values JSON 문자열. toleration·replicaCount를 포함한다. EKS 관리형 애드온은 CRD를 자체 처리하므로 installCRDs 불필요. dev에서 replicaCount=1로 설정하여 시스템 노드 pod 슬롯을 절약한다. null이면 기본값(replicaCount=2) 사용 | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS 클러스터 이름 (IAM Role, Security Group 등 연관 리소스의 Name에도 사용됨) | `string` | n/a | yes |
| <a name="input_coredns_configuration_values"></a> [coredns\_configuration\_values](#input\_coredns\_configuration\_values) | CoreDNS EKS 관리형 애드온 configuration\_values JSON 문자열. dev에서 replicaCount=1로 설정하여 시스템 노드 pod 슬롯을 절약한다. null이면 기본값(replicaCount=2) 사용 | `string` | `null` | no |
| <a name="input_ebs_csi_configuration_values"></a> [ebs\_csi\_configuration\_values](#input\_ebs\_csi\_configuration\_values) | EBS CSI Driver EKS 관리형 애드온 configuration\_values JSON 문자열. dev에서 controller.replicaCount=1로 설정하여 시스템 노드 pod 슬롯을 절약한다. null이면 기본값(replicaCount=2) 사용 | `string` | `null` | no |
| <a name="input_enabled_log_types"></a> [enabled\_log\_types](#input\_enabled\_log\_types) | 활성화할 컨트롤 플레인 로그 타입 목록. 빈 리스트이면 비활성화 (CloudWatch Logs 비용 절감). 가능한 값: api, audit, authenticator, controllerManager, scheduler | `list(string)` | `[]` | no |
| <a name="input_endpoint_public_access"></a> [endpoint\_public\_access](#input\_endpoint\_public\_access) | EKS API 서버 퍼블릭 엔드포인트 활성화 여부. develop=true(로컬 kubectl 접근), production=false(VPN/Bastion 경유) | `bool` | `false` | no |
| <a name="input_endpoint_public_access_cidrs"></a> [endpoint\_public\_access\_cidrs](#input\_endpoint\_public\_access\_cidrs) | EKS API 서버 퍼블릭 엔드포인트 허용 CIDR 목록. endpoint\_public\_access=true 시 반드시 IP를 제한해야 한다. 기본값 0.0.0.0/0은 인터넷 전체 노출이므로 환경별로 반드시 재정의할 것. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_environment"></a> [environment](#input\_environment) | 배포 환경 (develop / production). 시스템 노드 그룹 이름 접미사로 사용되어 AWS 콘솔에서 환경을 즉시 식별할 수 있게 한다. | `string` | n/a | yes |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes 버전. AWS EKS가 지원하는 버전만 지정 가능 (예: "1.32") | `string` | n/a | yes |
| <a name="input_node_security_group_additional_rules"></a> [node\_security\_group\_additional\_rules](#input\_node\_security\_group\_additional\_rules) | node\_sg에 추가할 보안 그룹 규칙 맵. node\_security\_group\_enable\_recommended\_rules가 커버하지 못하는 규칙을 환경별로 주입한다. 업스트림 모듈의 node\_security\_group\_additional\_rules 스키마를 따른다. | `any` | `{}` | no |
| <a name="input_node_security_group_tags"></a> [node\_security\_group\_tags](#input\_node\_security\_group\_tags) | node SG에 추가할 태그 맵. Karpenter SG 탐색 태그(karpenter.sh/discovery) 등 node SG 전용 태그에만 사용한다. additional\_tags는 default\_tags로 관리되므로 이 변수는 node SG에만 적용이 필요한 태그에 한정한다. karpenter.sh/discovery 값은 EC2NodeClass securityGroupSelectorTerms 및 cluster\_name과 반드시 일치해야 한다. | `map(string)` | `{}` | no |
| <a name="input_project"></a> [project](#input\_project) | 프로젝트 이름. 시스템 노드 그룹 이름 조합에 사용된다 ({project}-system-{environment}). cluster\_name 대신 사용하는 이유: cluster\_name은 project+environment를 이미 포함해 이름이 길어지면 IAM role name\_prefix 38자 한도를 초과한다. | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | 노드 그룹(Managed Node Group)을 배치할 서브넷 ID 목록. 멀티 AZ 고가용성을 위해 최소 2개 이상의 서브넷(다른 AZ) 필요 | `list(string)` | n/a | yes |
| <a name="input_system_node_ami_type"></a> [system\_node\_ami\_type](#input\_system\_node\_ami\_type) | 시스템 노드 그룹 AMI 타입. AL2023\_x86\_64\_STANDARD = Amazon Linux 2023 x86\_64 기본 이미지 | `string` | `"AL2023_x86_64_STANDARD"` | no |
| <a name="input_system_node_capacity_type"></a> [system\_node\_capacity\_type](#input\_system\_node\_capacity\_type) | 시스템 노드 그룹 용량 타입(ON\_DEMAND 또는 SPOT). 이 노드 그룹은 Karpenter(클러스터 오토스케일러) 자체와 CoreDNS가 실행되는 전용 노드다 — SPOT 중단 시 Karpenter가 죽어 신규 노드 프로비저닝이 불가능해지고 클러스터 자가 회복 능력이 상실된다. 비용 절감이 필요하면 이 리스크를 감수할 환경에서만 명시적으로 SPOT을 선택한다(예: 실습용 develop). production처럼 가용성이 중요한 환경은 ON\_DEMAND를 유지한다 | `string` | `"ON_DEMAND"` | no |
| <a name="input_system_node_desired_size"></a> [system\_node\_desired\_size](#input\_system\_node\_desired\_size) | 시스템 노드 그룹 초기(희망) 노드 수 | `number` | `2` | no |
| <a name="input_system_node_instance_types"></a> [system\_node\_instance\_types](#input\_system\_node\_instance\_types) | 시스템 노드 그룹 EC2 인스턴스 타입 목록 (우선순위 순). Karpenter, CoreDNS, LBC 등 시스템 애드온이 실행되므로 최소 t3.medium 이상 권장 | `list(string)` | <pre>[<br/>  "t3.medium"<br/>]</pre> | no |
| <a name="input_system_node_max_size"></a> [system\_node\_max\_size](#input\_system\_node\_max\_size) | 시스템 노드 그룹 최대 노드 수 | `number` | `3` | no |
| <a name="input_system_node_min_size"></a> [system\_node\_min\_size](#input\_system\_node\_min\_size) | 시스템 노드 그룹 최소 노드 수 | `number` | `1` | no |
| <a name="input_upgrade_policy"></a> [upgrade\_policy](#input\_upgrade\_policy) | 클러스터 지원 정책. EXTENDED = 표준 지원 종료 후 Extended Support 자동 진입($0.60/hr 추가), STANDARD = 표준 지원 종료 후 다음 버전으로 자동 업그레이드. null이면 AWS 기본값(EXTENDED) 사용 | <pre>object({<br/>    support_type = optional(string, "EXTENDED")<br/>  })</pre> | `null` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | EKS 클러스터 및 노드 Security Group을 생성할 VPC ID | `string` | n/a | yes |
| <a name="input_zonal_shift_config"></a> [zonal\_shift\_config](#input\_zonal\_shift\_config) | ARC Zonal Shift 활성화 여부. null이면 모듈 기본값(비활성화) 사용. 콘솔에서 값을 변경하면 Terraform 드리프트가 발생하므로 반드시 이 변수로 명시적으로 관리한다. | <pre>object({<br/>    enabled = optional(bool)<br/>  })</pre> | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cluster_certificate_authority_data"></a> [cluster\_certificate\_authority\_data](#output\_cluster\_certificate\_authority\_data) | 클러스터 통신에 필요한 Base64 인코딩 CA 인증서 데이터 (kubeconfig에 포함됨) |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | EKS API 서버 엔드포인트 URL (kubectl, Helm 등에서 사용) |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | EKS 클러스터 이름 |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | EKS가 생성한 클러스터(컨트롤 플레인) Security Group ID |
| <a name="output_ebs_csi_role_arn"></a> [ebs\_csi\_role\_arn](#output\_ebs\_csi\_role\_arn) | EBS CSI Driver Pod Identity IAM Role ARN |
| <a name="output_node_role_arn"></a> [node\_role\_arn](#output\_node\_role\_arn) | 시스템 노드 그룹 IAM Role ARN. Karpenter가 노드를 aws-auth ConfigMap에 등록할 때 참조한다 |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | 노드 그룹 공유 Security Group ID (추가 SG 규칙 연결 시 참조) |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | IRSA용 OIDC Provider ARN. blueprints 모듈(LBC, ExternalDNS, Karpenter)과 EBS CSI IRSA 구성에 사용된다 |
| <a name="output_vpc_cni_role_arn"></a> [vpc\_cni\_role\_arn](#output\_vpc\_cni\_role\_arn) | VPC CNI Pod Identity IAM Role ARN |
<!-- END_TF_DOCS -->