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

  # discovery된 spoke를 실제 EKS 클러스터 이름으로 재색인 — module.gitops_bridge_spoke의
  # for_each 키가 된다(gitops-bridge-spokes.tf 참조). SSM 경로에 존재하는 것 자체가 "등록됨"이므로
  # 구버전의 enabled 플래그는 더 이상 필요 없다(파라미터 부재 = 미등록).
  #
  # [별칭 계층 제거 — "dev"/"prod" 대신 payload.cluster_name(실제 이름)을 그대로 키로 쓴다]
  # 과거엔 이 자리에서 environment(develop/production) → "dev"/"prod" 1:1 맵으로 재색인했다.
  # 이 맵은 environment당 spoke를 정확히 1개까지만 표현할 수 있어(같은 environment로 두 번째
  # spoke가 등록되면 for 표현식 키가 중복돼 즉시 깨짐) 대규모 멀티 클러스터(같은 environment에
  # 클러스터가 여러 개)를 구조적으로 지원하지 못했다. cluster_name은 애초에 SSM 레지스트리 경로
  # 세그먼트 자체가 실제 EKS 클러스터 이름이라(gitops-bridge-registry.tf의 spoke 쪽
  # aws_ssm_parameter.name 참조) 전역적으로 유일함이 이미 보장된다 — 별도 별칭 매핑 없이 그대로
  # for_each 키로 써도 안전하다. environment-tier 라우팅(devops-manifest의 workload
  # ApplicationSet이 dev/prod 중 어디로 배포할지 결정하는 것)은 이 cluster_name 값이 아니라
  # vendor 모듈이 별도로 심어주는 `environment` 라벨(develop/production, 아래
  # module.gitops_bridge_spoke의 cluster.environment)로 분리해서 처리한다 — addon-spoke
  # ApplicationSet이 이미 cluster_name이 아니라 역할 라벨로 매칭하는 것과 동일한 원칙
  # (식별자와 그룹핑 키를 분리한다).
  gitops_bridge_spokes = {
    for name, payload in local.gitops_bridge_registry_raw :
    payload.cluster_name => payload
  }
}

################################################################################
# GitOps Bridge Hub — 자기 자신을 가리키는 cluster Secret 데이터 (gitops-bridge-irsa.tf 참조)
################################################################################
locals {
  # monitoring 자기 자신을 가리키는 cluster Secret 데이터.
  # server/config는 일부러 넣지 않는다 — vendor 모듈(gitops-bridge-dev/gitops-bridge/helm)이
  # cluster.server/cluster.config를 안 받으면 `server = https://kubernetes.default.svc`,
  # `config = {tlsClientConfig: {insecure: false}}`로 자동 채운다.
  # 이 값이 ArgoCD 자신의 "in-cluster" 개념과 동일해서, 별도 IRSA/Access Entry/RBAC 체인 없이도
  # 항상 유효하다(gitops-bridge-irsa.tf 파일 헤더 참고). 남기는 건 metadata뿐이고, 이건 addon
  # ApplicationSet들의 `{{metadata.annotations.xxx}}` 브릿지용으로 여전히 필요하다.
  #
  # 스키마 근거: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters
  #
  # [metadata — ApplicationSet cluster generator용 메타데이터 브릿지]
  # 공식 gitops-bridge-dev 패턴(https://github.com/gitops-bridge-dev/gitops-bridge)을 따른다:
  # Terraform이 만든 addon IAM Role ARN 등을 이 Secret의 K8s object metadata.annotations로
  # 기록해두면, ApplicationSet의 `clusters` generator가 이 Secret을 순회하며
  # `{{metadata.annotations.lbc_role_arn}}` 같은 템플릿 표현식으로 각 Application에 주입할
  # 수 있다. dev/prd를 spoke로 등록하면서 클러스터마다 IAM Role ARN 등의 값이 달라지므로,
  # devops-manifest의 addon values-override.yaml에 값을 직접 하드코딩하는 대신 이 브릿지로
  # 클러스터별 값을 동적으로 전달한다.
  #
  # [WHY — 이 local이 kubernetes_secret_v1 리소스가 아니라 module.eks_addons에 넘길 변수인 이유]
  # ArgoCD 설치 주체(gitops-bridge-dev/gitops-bridge/helm)가 cluster Secret 생성까지
  # 전담한다(modules/eks-addons/2.0.0/main.tf의 module "gitops_bridge_bootstrap" 참고). 그래서
  # 이 root는 리소스를 직접 만들지 않고, "Hub 전용 값(root에서만 계산 가능한 것)"만 조립해
  # module.eks_addons의 gitops_bridge_hub 변수로 넘긴다. addon별 IRSA Role ARN처럼 그 모듈
  # 스스로 이미 계산해둔 값(gitops_metadata)까지 여기서 미리 합쳐 넣으면 "module.eks_addons의
  # 출력을 같은 module.eks_addons의 입력으로 되먹이는" 순환 참조가 된다 — 그 merge는 공유
  # 모듈 내부(형제 module 참조)에서 이뤄진다(modules/eks-addons/2.0.0/main.tf 참고).
  gitops_bridge_hub_cluster = {
    # [별칭 계층 제거] spoke와 동일하게 실제 EKS 클러스터 이름을 그대로 쓴다(과거
    # "monitoring-self"라는 별도 별칭을 썼으나, spoke의 dev/prod 별칭을 없애면서 생기는
    # 비대칭을 없애기 위해 Hub도 함께 전환했다). 이 값을 참조하는 두 곳(root-app-addons.yaml의
    # selector, bootstrap/root-app-addons.yaml 참조)도 함께 갱신했다 — Hub는 spoke와 달리
    # 인스턴스가 항상 1개뿐이라 "여러 개 등록" 문제는 없지만, cluster_name이 식별자 역할만
    # 하도록 통일하는 편이 나머지 두 곳(spoke)과 같은 원칙을 유지한다.
    cluster_name = local.cluster_name
    # gitops-bridge-dev/gitops-bridge/helm은 이 값을 생략하면 내부 기본값 "dev"를 cluster
    # Secret의 labels/annotations에 그대로 찍는다(모듈 소스: `environment = try(var.cluster.
    # environment, "dev")`) — dev/prd를 spoke로 등록해 label 셀렉터를 실사용하는 상태에서는
    # monitoring이 dev 전용 템플릿에 잘못 매칭될 수 있어 명시한다.
    environment = "monitoring"
    # server/config는 의도적으로 생략 — 위 참고(vendor 기본값이 in-cluster로 자동 대체).
    metadata = {
      aws_cluster_name              = local.cluster_name
      aws_region                    = "ap-northeast-2"
      aws_account_id                = data.aws_caller_identity.current.account_id
      vpc_id                        = local.vpc_id
      # aws_iam_role.argocd_image_updater.arn(Computed 속성) 대신 같은 리소스의 .name을
      # 쓴다 — .arn은 최초(state 비어있는) apply 시점에 미지값이라, 이 값을 담는
      # gitops_bridge_hub_cluster 전체가 미지로 취급되어 kubernetes_secret_v1.cluster의
      # count 계산이 실패한다(vendor 모듈 gitops-bridge-dev/gitops-bridge/helm,
      # `count = var.create && (var.cluster != null)`). .name은 config에 정적으로
      # 지정한 값이라 plan 시점에 이미 알려져 있어 이 문제를 회피하면서도, 이름 패턴을
      # argocd-image-updater.tf 한 곳에서만 정의하도록 유지한다(리터럴 문자열로 다시
      # 조합하면 그 파일의 name이 바뀔 때 여기서도 따로 갱신해야 하는 이중 관리가 된다).
      argocd_image_updater_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${aws_iam_role.argocd_image_updater.name}"
      # workload 계정은 "클러스터마다 달라지는 값"은 아니지만(2계정 토폴로지 자체가
      # 프로젝트 상수), 동적으로 받아올 수 있는 값은 하드코딩하지 않는다는 원칙에 따라
      # 이 값도 devops-manifest에 직접 박아넣지 않고 동일한 브릿지로 전달한다 — workload
      # 계정이 바뀌어도 이 값 한 곳만 갱신하면 되고 devops-manifest 코드는 안 건드려도 된다.
      workload_account_id                 = local.workload_account_id
      external_dns_cross_account_role_arn = local.external_dns_cross_account_role_arn
      # devops-manifest 저장소 좌표(repoURL/path/revision)는 여기 없다 — bootstrap/
      # root-app-addons.yaml에 직접 하드코딩돼 있다(그 파일 상단 WHY 참고). AWS 리소스
      # output이 아니라 이 root 하나에만 쓰이는 정적 컨벤션이라 브릿지로 전달할 이유가 없다.
    }
  }
}
