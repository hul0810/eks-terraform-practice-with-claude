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

  # IRSA Trust Policy 조건 키(sub/aud)에 필요한 OIDC issuer 호스트.
  # blueprints가 내부적으로 처리하는 IRSA와 달리 argocd-image-updater는 blueprints 밖에서
  # 수동으로 IRSA를 구성하므로(argocd-image-updater.tf) 이 값을 직접 유도해야 한다.
  oidc_provider_url = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # catalog/order/api-gateway 이미지가 위치한 workload 계정 — Terraform 외부 관리 리소스(하드코딩).
  # argocd-image-updater.tf의 ECR registries.conf api_url/prefix에서 참조한다.
  workload_account_id = "657231015203"

  # eks/locals.tf의 kubernetes_version과 동기화
  cluster_version = "1.34"

  # ArgoCD(Terraform이 직접 Helm을 설치하는 유일한 addon)만 대상 — 나머지 addon은
  # ArgoCD/devops-manifest가 replica 수를 결정한다(modules/eks-addons/2.0.0/variables.tf
  # 참조). argocd_ha_enabled=false인 동안은 이 값 자체가 안 쓰이므로(항상 1) 모듈 기본값
  # (2)을 그대로 둔다 — HA를 켤 때 여기서 조정한다.
  replica_counts = {}

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
    karpenter_chart_version        = "1.12.1"
    external_secrets_chart_version = "2.7.0"
    # argocd_image_updater_chart_version — GitOps Bridge(Phase 6-4)로 이관 완료. 버전은 이제
    # eks-practice-devops-manifest 저장소의 Application이 관리한다.

    # [LBC/ExternalDNS/Karpenter/External Secrets 공통 주의]
    # 이 4개는 IAM(IRSA)이 있는 addon이라 enable_*를 false로 바꾸면 안 된다 —
    # module.eks_blueprints_addons_gitops 인스턴스에서 create_kubernetes_resources=false가
    # 이미 Helm release 생성을 막고 있으므로, 이 enable_*=true는 "Helm을 설치하라"가 아니라
    # "IAM Role/Policy(+Karpenter는 노드 IAM·SQS·EventBridge까지)는 계속 유지하라"는 뜻으로
    # 재해석된다. false로 바꾸면 ArgoCD가 참조 중인 IRSA Role ARN이 통째로 사라져 addon이 깨진다.
    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    # pyhtest.com zone ARN — workload 계정 소유, Terraform 외부 관리 리소스 (하드코딩)
    # ExternalDNS IRSA가 external_dns_cross_account_role_arn을 assume하여 이 zone에 접근한다
    external_dns_route53_zone_arns = ["arn:aws:route53:::hostedzone/Z0947901KS8HHREY0RFC"]
    enable_karpenter               = true
    enable_external_secrets        = true
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
    # ArgoCD Application Notifications의 Slack 알림 서비스 활성화 여부. 전용
    # IRSA/SecretStore(notifications-irsa.tf)가 준비되어 있어야 한다. Argo Rollouts는
    # Terraform이 전혀 관여하지 않는 addon이라 이 목록에 없다 — 그쪽 Slack 설정은
    # devops-manifest의 values-override.yaml 쪽 관심사다.
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

################################################################################
# GitOps Bridge Registry — discovery 결과 조합 (gitops-bridge-registry.tf 참조)
################################################################################
locals {
  # 지금 이 레지스트리에 쓰기가 필요한 계정만 명시(gitops-bridge-registry.tf의 신뢰 정책 참조).
  # 계정이 늘면 여기에만 추가하면 된다.
  trusted_spoke_account_ids = [local.workload_account_id]

  # [논리적 라우팅 별칭 — dev/prod]
  # devops-manifest의 워크로드 ApplicationSet(order/gateway/catalog)이 ArgoCD 클러스터 Secret의
  # `cluster_name` 라벨을 `matchLabels: cluster_name: dev|prod`로 선택하고, addon/workload
  # ApplicationSet들은 destination/namespace를 `{{name}}`/`eks-practice-{{name}}`으로
  # 템플릿한다(project/environments/develop이 이미 이 별칭으로 라우팅되고 있음, 실제 검증됨).
  # 이 별칭을 실제 EKS 클러스터 이름(예: eks-practice-dev)으로 바꾸면 그 라우팅이 전부 깨진다.
  # 레지스트리 payload의 environment(develop/production)는 이미 아는 값이라, 새 필드를
  # 추가하지 않고 이 매핑 하나로 별칭을 유도한다.
  environment_spoke_alias = {
    develop    = "dev"
    production = "prod"
  }

  # aws_ssm_parameters_by_path는 names/values를 병렬 배열로 반환한다(공식 스키마 — 두 배열의
  # 순서가 항상 일치). zipmap으로 {parameter_name => JSON string} 맵을 만든 뒤 jsondecode한다.
  # values는 SecureString 여부와 무관하게 항상 sensitive로 마킹되는데(AWS provider 공식 동작),
  # 이 경로에는 endpoint/ARN 같은 식별자만 있고 진짜 비밀이 없다(그래서 애초에 SecureString이
  # 아니라 String으로 설계했다) — nonsensitive()로 해제해 plan 출력에서 정상적으로 diff를
  # 확인할 수 있게 한다.
  gitops_bridge_registry_raw = {
    for name, value in zipmap(
      data.aws_ssm_parameters_by_path.gitops_bridge_registry.names,
      nonsensitive(data.aws_ssm_parameters_by_path.gitops_bridge_registry.values)
    ) : name => jsondecode(value)
  }

  # discovery된 spoke를 "dev"/"prod" 별칭으로 재색인 — module.gitops_bridge_spoke의 for_each
  # 키가 된다(gitops-bridge-spokes.tf 참조). SSM 경로에 존재하는 것 자체가 "등록됨"이므로
  # 구버전의 enabled 플래그는 더 이상 필요 없다(파라미터 부재 = 미등록).
  gitops_bridge_spokes = {
    for name, payload in local.gitops_bridge_registry_raw :
    local.environment_spoke_alias[payload.environment] => payload
  }
}
