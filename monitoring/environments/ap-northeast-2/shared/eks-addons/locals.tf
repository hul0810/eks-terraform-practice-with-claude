locals {
  environment = "monitoring"
  project     = "eks-practice"

  environment_short = "mon"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.eks.outputs.cluster_endpoint
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  vpc_id            = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  # GitOps Bridge Hub(Phase 6-1): ArgoCD cluster Secret의 config.tlsClientConfig.caData에 필요
  cluster_certificate_authority_data = data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data

  # IRSA Trust Policy 조건 키(sub/aud)에 필요한 OIDC issuer 호스트.
  # blueprints가 내부적으로 처리하는 IRSA와 달리 argocd-image-updater는 blueprints 밖에서
  # 수동으로 IRSA를 구성하므로(argocd-image-updater.tf) 이 값을 직접 유도해야 한다.
  oidc_provider_url = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # catalog/order/api-gateway 이미지가 위치한 workload 계정 — Terraform 외부 관리 리소스(하드코딩).
  # argocd-image-updater.tf의 ECR registries.conf api_url/prefix에서 참조한다.
  workload_account_id = "657231015203"

  # eks/locals.tf의 kubernetes_version과 동기화
  cluster_version = "1.34"

  # monitoring: 단일 시스템 노드(비용 절감)로 모든 애드온 replica=1
  replica_counts = {
    lbc              = 1
    karpenter        = 1
    external_dns     = 1
    metrics_server   = 1
    argo_rollouts    = 1
    external_secrets = 1
  }

  # *.pyhtest.com ACM 인증서 ARN — monitoring 계정, AWS CLI 외부 관리 리소스
  # 발급: aws acm request-certificate --domain-name "*.pyhtest.com" --validation-method DNS \
  #         --region ap-northeast-2 --profile terraform-monitoring
  # data.aws_acm_certificate로 domain 기준 동적 조회 (data.tf 참조) — 재발급 시 ARN 수동 교체 불필요
  acm_certificate_arn = data.aws_acm_certificate.pyhtest_wildcard.arn

  # workload 계정 Route53 크로스 계정 Role ARN — ExternalDNS --aws-assume-role에 주입
  #
  # [최초 부트스트랩 순환 의존 해소]
  # monitoring/eks-addons와 external-dns-cross-account-role이 서로의 output을 참조하는 양방향 의존이 발생한다.
  # try()로 소프트 참조를 만들어 external-dns-cross-account-role state 미존재 시 "" 폴백 → 아래 순서로 적용한다:
  #   1단계: terraform apply                        (external-dns-cross-account-role 참조 없이 ExternalDNS IRSA 생성)
  #   2단계: external-dns-cross-account-role apply   (monitoring state에서 IRSA ARN 읽어 Trust Policy 설정)
  #   3단계: terraform apply                        (cross-account role ARN 주입 → cross-account DNS 활성화)
  external_dns_cross_account_role_arn = try(data.terraform_remote_state.external_dns_cross_account_role.outputs.role_arn, "")

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전
    lbc_chart_version              = "3.4.0"
    external_dns_chart_version     = "1.14.5"
    metrics_server_chart_version   = "3.12.2"
    karpenter_chart_version        = "1.12.1"
    external_secrets_chart_version = "2.7.0"
    # argocd_image_updater_chart_version — GitOps Bridge(Phase 6-4)로 이관 완료. 버전은 이제
    # eks-practice-devops-manifest 저장소의 Application이 관리한다.

    # [LBC/ExternalDNS/Karpenter/External Secrets — GitOps Bridge 이관 완료 addon 공통 주의]
    # 이 4개는 IAM(IRSA)이 있는 addon이라 metrics-server/argo-rollouts와 달리 enable_*를
    # false로 바꾸면 안 된다 — module.eks_blueprints_addons_gitops 인스턴스에서
    # create_kubernetes_resources=false가 이미 Helm release 생성을 막고 있으므로, 이
    # enable_*=true는 "Helm을 설치하라"가 아니라 "IAM Role/Policy(+Karpenter는 노드 IAM·SQS·
    # EventBridge까지)는 계속 유지하라"는 뜻으로 재해석된다. false로 바꾸면 ArgoCD가 참조 중인
    # IRSA Role ARN이 통째로 사라져 addon이 깨진다.
    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    # pyhtest.com zone ARN — workload 계정 소유, Terraform 외부 관리 리소스 (하드코딩)
    # ExternalDNS IRSA가 external_dns_cross_account_role_arn을 assume하여 이 zone에 접근한다
    external_dns_route53_zone_arns = ["arn:aws:route53:::hostedzone/Z0947901KS8HHREY0RFC"]
    # GitOps Bridge(Phase 6-2)로 이관 완료 — ArgoCD Application(devops-manifest
    # charts/eks-addons/metrics-server)이 관리한다. Terraform state에서는 이미
    # `terraform state rm`으로 분리했고(실제 리소스는 유지, 무중단 인수 완료), 이 플래그를
    # false로 유지해야 다음 plan이 "없어졌으니 재생성"으로 오판하지 않는다.
    enable_metrics_server   = false
    enable_karpenter        = true
    enable_external_secrets = true
    # ArgoCD GitHub App 인증 정보(SSM SecureString)만 읽도록 스코프 — 계정 내 모든 파라미터
    # 와일드카드(blueprints 기본값) 대신 이 prefix로 제한한다.
    # argocd-image-updater/* : Image Updater가 이미지 태그 갱신을 커밋할 때 쓰는 GitHub App
    # 인증 정보 — ArgoCD 레포 접근용(argocd/github-app/*)과 용도가 달라 별도 App/경로로 분리한다.
    # notifications/slack-bot-token은 더 이상 이 목록에 포함되지 않는다 — Argo Rollouts/ArgoCD
    # Notifications는 전용 IRSA(notifications-irsa.tf, aws_iam_role.notifications_slack)로
    # 분리되어 이 external-secrets-sa 공용 Role이 읽을 필요가 없다(최소 권한 원칙).
    external_secrets_ssm_parameter_arns = [
      "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/monitoring/argocd/github-app/*",
      "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/monitoring/argocd-image-updater/*",
    ]
    # SSM SecureString 기본 키(alias/aws/ssm)만 복호화 허용 — 계정 내 모든 KMS 키 와일드카드 대신 최소 권한
    external_secrets_kms_key_arns = [data.aws_kms_alias.ssm_default.target_key_arn]

    # monitoring 클러스터는 OTel의 Hub이므로 spoke collector를 설치하지 않는다.
    # OTel Operator와 Gateway는 observability/ root module에서 관리한다.
    enable_otel_spoke_collector = false

    enable_argocd = true
    # GitOps Bridge(Phase 6-4)로 이관 완료 — ArgoCD Application(devops-manifest
    # charts/eks-addons/argo-rollouts)이 관리한다. Terraform state에서는 이미
    # `terraform state rm`으로 분리했고(실제 리소스는 유지, 무중단 인수 완료), 이 플래그를
    # false로 유지해야 다음 plan이 "없어졌으니 재생성"으로 오판하지 않는다.
    #
    # [주의 — 예전 경고, 지금은 해당 없음] 예전엔 "false로 되돌리면 Argo Rollouts
    # Notifications(Slack) 알림 기능이 조용히 깨진다"는 경고가 있었다 — 그건 Terraform이
    # Helm release 자체를 설치하던 시절, false가 "addon 자체를 안 만든다"는 뜻이었을 때
    # 얘기다. 지금은 false가 "설치는 ArgoCD가 한다"는 뜻이고, notifications 설정
    # (local.argo_rollouts_values, notifiers/templates/triggers 전체)도 devops-manifest의
    # values-override.yaml로 그대로 이관되어 동일하게 동작한다 — 이 플래그로 알림이
    # 깨지지 않는다.
    enable_argo_rollouts        = false
    argo_rollouts_chart_version = "2.38.1"
    # Argo Rollouts Notifications의 Slack 알림 서비스(templates/triggers 포함) 활성화 여부.
    # 전용 IRSA/SecretStore(notifications-irsa.tf)가 준비되어 있어야 한다.
    argo_rollouts_notifications_slack_enabled = true
    # ArgoCD Application Notifications의 Slack 알림 서비스 활성화 여부. 동일하게 전용
    # IRSA/SecretStore(notifications-irsa.tf)가 준비되어 있어야 한다.
    argocd_notifications_slack_enabled = true
    argocd_chart_version               = "9.5.21"
    # monitoring: 단일 시스템 노드(비용 절감)라 HA 불필요
    argocd_ha_enabled = false

    # ArgoCD 외부 접근 설정 — argocd.pyhtest.com
    # ALB가 TLS를 종료하고 백엔드는 server.insecure=true로 평문 HTTP 서빙
    argocd_ingress_enabled  = true
    argocd_ingress_hostname = "argocd.pyhtest.com"
    # AWS ALB 이름 최대 32자 제한 — "eks-practice-argocd-mon-alb" = 28자
    argocd_ingress_alb_name = "${local.project}-argocd${local.name_suffix}-alb"
    # dex(SSO) 미활성 상태에서 admin 계정만으로 인증 → 운영자 IP로만 접근 허용
    argocd_ingress_allowed_cidrs = [data.aws_ssm_parameter.operator_ip_cidr.value]

    # ArgoCD admin 초기 패스워드 (bcrypt 해시)
    # 패스워드 변경 시: 새 해시와 argocd_admin_password_mtime을 함께 갱신해야 ArgoCD가 변경을 감지한다.
    # 해시 재생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt()).decode())"
    # 주의: Terraform bcrypt() 함수를 직접 사용하지 말 것 — apply마다 ArgoCD pod 재시작 유발
    argocd_admin_password_bcrypt = data.aws_ssm_parameter.argocd_admin_password_bcrypt.value
    argocd_admin_password_mtime  = "2026-07-01T00:00:00Z"
  }

  # karpenter_node_pools — GitOps Bridge(Phase 6-4)로 이관 완료. NodePool/EC2NodeClass 스펙은
  # 이제 eks-practice-devops-manifest 저장소의 charts/eks-addons/karpenter-resources/에서
  # 관리한다 — 값을 바꾸려면 이 저장소가 아니라 그쪽 저장소를 수정한다.
}
