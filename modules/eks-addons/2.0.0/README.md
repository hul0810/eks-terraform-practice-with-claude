<!-- BEGIN_TF_DOCS -->
<!-- 이 파일은 terraform-docs가 자동 생성합니다. 직접 수정하지 마세요. -->
<!-- 설계 결정과 WHY는 같은 디렉토리의 CLAUDE.md를 참조하세요. -->

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.50.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | 2.17.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 3.2.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_eks_blueprints_addons"></a> [eks\_blueprints\_addons](#module\_eks\_blueprints\_addons) | aws-ia/eks-blueprints-addons/aws | ~> 1.23.0 |
| <a name="module_eks_blueprints_addons_argocd"></a> [eks\_blueprints\_addons\_argocd](#module\_eks\_blueprints\_addons\_argocd) | aws-ia/eks-blueprints-addons/aws | ~> 1.23.0 |
| <a name="module_eks_blueprints_addons_gitops"></a> [eks\_blueprints\_addons\_gitops](#module\_eks\_blueprints\_addons\_gitops) | aws-ia/eks-blueprints-addons/aws | ~> 1.23.0 |

## Resources

| Name | Type |
|------|------|
| [aws_eks_access_entry.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [helm_release.otel_operator_spoke](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_manifest.otel_spoke_node](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_manifest.otel_spoke_singleton](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.otel_collector](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_tags"></a> [additional\_tags](#input\_additional\_tags) | 모든 리소스에 추가할 태그 맵. providers.tf의 default\_tags로 공통 태그를 관리하므로, 이 변수는 호출자가 추가로 전달할 태그에만 사용한다 | `map(string)` | `{}` | no |
| <a name="input_argo_rollouts_chart_version"></a> [argo\_rollouts\_chart\_version](#input\_argo\_rollouts\_chart\_version) | Argo Rollouts Helm chart 버전 (예: "2.38.1"). enable\_argo\_rollouts=false이면 미사용 — null 허용 | `string` | `null` | no |
| <a name="input_argo_rollouts_extension_enabled"></a> [argo\_rollouts\_extension\_enabled](#input\_argo\_rollouts\_extension\_enabled) | ArgoCD UI의 Argo Rollouts rollout-extension 활성화 여부. null이면 enable\_argo\_rollouts를 그대로 따른다(기본 동작) — GitOps Bridge로 Argo Rollouts의 Helm 설치만 ArgoCD로 넘어가고 Terraform은 enable\_argo\_rollouts=false로 손을 뗀 환경(클러스터엔 Argo Rollouts가 여전히 존재)에서는 true를 명시해야 extension이 계속 표시된다. | `bool` | `null` | no |
| <a name="input_argo_rollouts_notifications_slack_enabled"></a> [argo\_rollouts\_notifications\_slack\_enabled](#input\_argo\_rollouts\_notifications\_slack\_enabled) | Argo Rollouts Notifications의 Slack 알림 서비스(notifications.notifiers["service.slack"]) 활성화 여부. true로 설정하는 환경은 대상 네임스페이스(argo-rollouts)에 argo-rollouts-notification-secret Secret(키 slack-token)이 미리 준비되어 있어야 한다(예: External Secrets Operator). | `bool` | `false` | no |
| <a name="input_argocd_admin_password_bcrypt"></a> [argocd\_admin\_password\_bcrypt](#input\_argocd\_admin\_password\_bcrypt) | ArgoCD admin 초기 패스워드의 bcrypt 해시. 설정하면 Helm 배포 시 argocd-secret에 주입된다. 비워두면 ArgoCD가 자동 생성한 시크릿을 사용하고 'argocd-initial-admin-secret'에서 확인해야 한다. 해시 생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'PASSWORD', bcrypt.gensalt()).decode())". 반드시 argocd\_admin\_password\_mtime과 함께 설정한다 | `string` | `""` | no |
| <a name="input_argocd_admin_password_mtime"></a> [argocd\_admin\_password\_mtime](#input\_argocd\_admin\_password\_mtime) | argocd\_admin\_password\_bcrypt와 짝을 이루는 타임스탬프 (RFC3339). ArgoCD가 이 값으로 패스워드 변경 여부를 판단하므로 패스워드 변경 시 반드시 함께 갱신해야 한다. 예: "2026-06-16T00:00:00Z" | `string` | `""` | no |
| <a name="input_argocd_chart_version"></a> [argocd\_chart\_version](#input\_argocd\_chart\_version) | ArgoCD Helm chart 버전 (예: "9.5.21") | `string` | n/a | yes |
| <a name="input_argocd_controller_irsa_role_arn"></a> [argocd\_controller\_irsa\_role\_arn](#input\_argocd\_controller\_irsa\_role\_arn) | ArgoCD application-controller ServiceAccount(argocd-application-controller)에 붙일 IRSA Role ARN. GitOps Bridge 패턴에서 ArgoCD가 다른/자기 자신 클러스터를 awsAuthConfig로 명시 등록할 때 필요. null이면 이 값을 주입하지 않는다(기존 in-cluster 암묵 등록만 쓰는 환경은 불필요). | `string` | `null` | no |
| <a name="input_argocd_ha_enabled"></a> [argocd\_ha\_enabled](#input\_argocd\_ha\_enabled) | ArgoCD HA 모드. true면 redis-ha 활성화 + server/repoServer/applicationSet replica를 replica\_counts.argocd\_server로 증설. false면 모든 컴포넌트 단일 replica, redis-ha 비활성 | `bool` | `false` | no |
| <a name="input_argocd_ingress_acm_certificate_arn"></a> [argocd\_ingress\_acm\_certificate\_arn](#input\_argocd\_ingress\_acm\_certificate\_arn) | ArgoCD ALB Ingress가 사용할 ACM 인증서 ARN. argocd\_ingress\_enabled=true일 때 필수 | `string` | `""` | no |
| <a name="input_argocd_ingress_alb_name"></a> [argocd\_ingress\_alb\_name](#input\_argocd\_ingress\_alb\_name) | ArgoCD server ALB Ingress의 ALB 이름 (alb.ingress.kubernetes.io/load-balancer-name). argocd\_ingress\_enabled=true일 때 필수. AWS ALB 이름 제한(최대 32자, 영문/숫자/하이픈)을 따라야 한다 | `string` | `""` | no |
| <a name="input_argocd_ingress_allowed_cidrs"></a> [argocd\_ingress\_allowed\_cidrs](#input\_argocd\_ingress\_allowed\_cidrs) | ArgoCD ALB Ingress 접근을 허용할 CIDR 목록 (ALB Security Group inbound 규칙). argocd\_ingress\_enabled=true일 때 필수 — dex 비활성화 상태에서 기본 admin 계정만으로 인증하므로 접근 IP를 제한한다 | `list(string)` | `[]` | no |
| <a name="input_argocd_ingress_enabled"></a> [argocd\_ingress\_enabled](#input\_argocd\_ingress\_enabled) | ArgoCD server에 ALB Ingress(외부 접근)를 구성할지 여부. true면 server.insecure=true로 전환되어 ALB가 TLS를 종료한다 | `bool` | `false` | no |
| <a name="input_argocd_ingress_hostname"></a> [argocd\_ingress\_hostname](#input\_argocd\_ingress\_hostname) | ArgoCD server Ingress의 호스트명 (예: "argo-develop.pyhtest.com"). argocd\_ingress\_enabled=true일 때 필수 | `string` | `""` | no |
| <a name="input_argocd_notifications_slack_enabled"></a> [argocd\_notifications\_slack\_enabled](#input\_argocd\_notifications\_slack\_enabled) | ArgoCD Application Notifications의 Slack 알림 서비스 활성화 여부. true로 설정하는 환경은 argocd 네임스페이스에 argocd-notifications-secret Secret(키 slack-token)이 미리 준비되어 있어야 한다(예: External Secrets Operator). true가 되면 ArgoCD 차트의 notifications 서브컴포넌트(별도 컨트롤러 파드)가 함께 활성화된다. | `bool` | `false` | no |
| <a name="input_cluster_endpoint"></a> [cluster\_endpoint](#input\_cluster\_endpoint) | EKS API 서버 엔드포인트 URL. eks-blueprints-addons 모듈의 필수 입력값 | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS 클러스터 이름. eks-blueprints-addons 모듈의 필수 입력값 | `string` | n/a | yes |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes 버전 (예: "1.33"). eks-blueprints-addons의 Helm chart 호환성 확인에 사용 | `string` | n/a | yes |
| <a name="input_create_kubernetes_resources"></a> [create\_kubernetes\_resources](#input\_create\_kubernetes\_resources) | ArgoCD와 GitOps Bridge로 이미 이관 완료된 addon(LBC 등, eks\_blueprints\_addons\_gitops 인스턴스)을 제외한 나머지 addon(ExternalDNS/Metrics Server/External Secrets/Karpenter/Argo Rollouts 중 아직 이관 안 된 것)의 Helm release 생성 여부. false로 바꾸면 이 addon들의 Kubernetes 리소스 생성을 한 번에 중단한다(AWS 쪽 IAM Role 등은 유지) — GitOps Bridge 최종 전환 시점에만 사용. LBC처럼 이미 이관 완료된 addon은 eks\_blueprints\_addons\_gitops에서 항상 비활성이라 이 변수의 영향을 받지 않는다. | `bool` | `true` | no |
| <a name="input_enable_argo_rollouts"></a> [enable\_argo\_rollouts](#input\_enable\_argo\_rollouts) | Argo Rollouts 설치 여부. Canary·Blue-Green 배포 전략을 Kubernetes에서 구현한다 | `bool` | `false` | no |
| <a name="input_enable_argocd"></a> [enable\_argocd](#input\_enable\_argocd) | ArgoCD 설치 여부 (GitOps 전환 Phase 5) | `bool` | `true` | no |
| <a name="input_enable_aws_load_balancer_controller"></a> [enable\_aws\_load\_balancer\_controller](#input\_enable\_aws\_load\_balancer\_controller) | AWS Load Balancer Controller IAM(IRSA Role/Policy) 생성 여부. eks\_blueprints\_addons\_gitops 인스턴스에서 create\_kubernetes\_resources가 항상 false로 고정되어 있어, 이 변수는 Helm release가 아니라 IAM 리소스 생성 여부만 제어한다 — Helm release는 ArgoCD(devops-manifest charts/eks-addons/aws-load-balancer-controller)가 관리한다. | `bool` | `true` | no |
| <a name="input_enable_external_dns"></a> [enable\_external\_dns](#input\_enable\_external\_dns) | ExternalDNS 설치 여부. false이면 blueprints가 관련 IAM Role과 Helm release를 생성하지 않는다 | `bool` | `true` | no |
| <a name="input_enable_external_secrets"></a> [enable\_external\_secrets](#input\_enable\_external\_secrets) | External Secrets Operator 설치 여부 | `bool` | `false` | no |
| <a name="input_enable_karpenter"></a> [enable\_karpenter](#input\_enable\_karpenter) | Karpenter 설치 여부. false이면 blueprints가 관련 IAM Role, SQS, EventBridge Rule, Helm release를 생성하지 않는다 | `bool` | `true` | no |
| <a name="input_enable_metrics_server"></a> [enable\_metrics\_server](#input\_enable\_metrics\_server) | Metrics Server 설치 여부 | `bool` | `true` | no |
| <a name="input_enable_otel_spoke_collector"></a> [enable\_otel\_spoke\_collector](#input\_enable\_otel\_spoke\_collector) | OTel spoke collector 설치 여부. true로 설정하면 OTel Operator와 DaemonSet·Deployment 수집기를 otel-collector 네임스페이스에 배포한다. otel\_gateway\_endpoint와 otel\_spoke\_operator\_chart\_version을 함께 설정해야 한다 | `bool` | `false` | no |
| <a name="input_external_dns_assume_role_arn"></a> [external\_dns\_assume\_role\_arn](#input\_external\_dns\_assume\_role\_arn) | ExternalDNS가 크로스 계정 Route53을 관리하기 위해 assume할 IAM Role ARN. 비어있으면 동일 계정 Route53 직접 접근 (dev/prd 기본값). monitoring처럼 Route53이 다른 계정에 있을 때 설정한다 | `string` | `""` | no |
| <a name="input_external_dns_chart_version"></a> [external\_dns\_chart\_version](#input\_external\_dns\_chart\_version) | ExternalDNS Helm chart 버전 (예: "1.14.5") | `string` | n/a | yes |
| <a name="input_external_dns_route53_zone_arns"></a> [external\_dns\_route53\_zone\_arns](#input\_external\_dns\_route53\_zone\_arns) | ExternalDNS가 레코드를 관리할 Route53 Hosted Zone ARN 목록. 빈 리스트이면 모든 Hosted Zone 접근 허용 (운영 환경에서는 반드시 명시할 것) | `list(string)` | `[]` | no |
| <a name="input_external_secrets_chart_version"></a> [external\_secrets\_chart\_version](#input\_external\_secrets\_chart\_version) | External Secrets Operator Helm chart 버전 (예: "2.7.0"). enable\_external\_secrets=false이면 미사용 — null 허용 | `string` | `null` | no |
| <a name="input_external_secrets_kms_key_arns"></a> [external\_secrets\_kms\_key\_arns](#input\_external\_secrets\_kms\_key\_arns) | External Secrets Operator가 SecureString 파라미터 복호화에 사용할 KMS Key ARN 목록. 빈 리스트이면 blueprints 기본값(모든 KMS 키 와일드카드 arn:aws:kms:*:*:key/*)을 사용 — 운영 환경에서는 반드시 명시할 것 | `list(string)` | `[]` | no |
| <a name="input_external_secrets_ssm_parameter_arns"></a> [external\_secrets\_ssm\_parameter\_arns](#input\_external\_secrets\_ssm\_parameter\_arns) | External Secrets Operator가 읽을 수 있는 SSM Parameter ARN 목록. 빈 리스트이면 blueprints 기본값(모든 파라미터 와일드카드 arn:aws:ssm:*:*:parameter/*)을 사용 — 운영 환경에서는 반드시 명시할 것 | `list(string)` | `[]` | no |
| <a name="input_karpenter_chart_version"></a> [karpenter\_chart\_version](#input\_karpenter\_chart\_version) | Karpenter Helm chart 버전 (예: "1.3.3") | `string` | n/a | yes |
| <a name="input_lbc_chart_version"></a> [lbc\_chart\_version](#input\_lbc\_chart\_version) | AWS Load Balancer Controller Helm chart 버전 (예: "3.4.0") | `string` | n/a | yes |
| <a name="input_metrics_server_chart_version"></a> [metrics\_server\_chart\_version](#input\_metrics\_server\_chart\_version) | Metrics Server Helm chart 버전 (예: "3.12.2") | `string` | n/a | yes |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | IRSA용 OIDC Provider ARN. blueprints 모듈이 LBC·ExternalDNS·Karpenter IAM Role 생성에 사용한다 | `string` | n/a | yes |
| <a name="input_otel_gateway_endpoint"></a> [otel\_gateway\_endpoint](#input\_otel\_gateway\_endpoint) | monitoring 클러스터 OTel Gateway Internal NLB 엔드포인트 (예: 'internal-xxxx.elb.ap-northeast-2.amazonaws.com:4317'). enable\_otel\_spoke\_collector=true일 때 필수 | `string` | `""` | no |
| <a name="input_otel_spoke_operator_chart_version"></a> [otel\_spoke\_operator\_chart\_version](#input\_otel\_spoke\_operator\_chart\_version) | OTel Operator Helm chart 버전 (예: '0.76.1'). enable\_otel\_spoke\_collector=true일 때 필수 | `string` | `null` | no |
| <a name="input_replica_counts"></a> [replica\_counts](#input\_replica\_counts) | 애드온별 Pod replica 수. 환경별로 HA/비용 요구사항에 맞게 조정한다. 기본값은 프로덕션 권장 최솟값 | <pre>object({<br/>    lbc              = optional(number, 2) # LBC: replicaCount 기본 2<br/>    karpenter        = optional(number, 2) # Karpenter: replicas 기본 2<br/>    external_dns     = optional(number, 1) # ExternalDNS: 기본 1 (단일 인스턴스로 충분)<br/>    metrics_server   = optional(number, 1) # MetricsServer: replicas 기본 1<br/>    argocd_server    = optional(number, 2) # ArgoCD HA 모드에서 server/repoServer/applicationSet replica 수<br/>    argo_rollouts    = optional(number, 1) # Argo Rollouts controller: 기본 1. 시스템 노드 HA(min>=2) 확보 후 2로 증설<br/>    external_secrets = optional(number, 1) # External Secrets Operator: replicaCount 기본 1<br/>  })</pre> | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | EKS 클러스터가 속한 VPC ID. LBC가 VPC ID를 IMDS에서 조회하지 않도록 직접 주입하는 용도였으나, LBC의 Helm release가 ArgoCD로 이관되며 이 값(devops-manifest의 charts/eks-addons/aws-load-balancer-controller/values-override.yaml의 vpcId)도 함께 옮겨가 이 버전(2.0.0)에서는 실제 사용처가 없다. 6-4 이후 vpc\_id가 필요한 다른 addon이 eks\_blueprints\_addons\_gitops로 이관되면 그때 다시 쓰일 수 있어 인터페이스는 유지한다. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_external_dns_role_arn"></a> [external\_dns\_role\_arn](#output\_external\_dns\_role\_arn) | ExternalDNS IRSA IAM Role ARN. blueprints가 생성한다. external\_dns\_route53\_zone\_arns가 비면 빈 문자열 반환 |
| <a name="output_external_secrets_role_arn"></a> [external\_secrets\_role\_arn](#output\_external\_secrets\_role\_arn) | External Secrets Operator IRSA IAM Role ARN. blueprints가 생성한다. Role 신뢰 정책의 OIDC sub 조건은 system:serviceaccount:external-secrets:external-secrets-sa로 고정된다 |
| <a name="output_karpenter_node_iam_role_name"></a> [karpenter\_node\_iam\_role\_name](#output\_karpenter\_node\_iam\_role\_name) | Karpenter 노드 IAM Role 이름. EC2NodeClass의 role 필드에 사용한다 |
| <a name="output_karpenter_role_arn"></a> [karpenter\_role\_arn](#output\_karpenter\_role\_arn) | Karpenter 컨트롤러 IRSA IAM Role ARN. blueprints가 생성한다 |
| <a name="output_lbc_role_arn"></a> [lbc\_role\_arn](#output\_lbc\_role\_arn) | AWS Load Balancer Controller IRSA IAM Role ARN. blueprints가 생성한다 |
<!-- END_TF_DOCS -->