resource "terraform_data" "validate_tags" {
  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_environments, local.common_tags.environment)
      error_message = "environment 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_environments)}. 현재 값: '${local.common_tags.environment}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_managed_by, local.common_tags.managed_by)
      error_message = "managed_by 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_managed_by)}. 현재 값: '${local.common_tags.managed_by}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_projects, local.common_tags.project)
      error_message = "project 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_projects)}. 현재 값: '${local.common_tags.project}'"
    }
  }
}

module "eks_addons" {
  # GitOps Bridge(Phase 6) 모듈 3분할(rest/argocd/gitops)은 develop/production이 여전히
  # 참조하는 1.0.0과 호환되지 않는 파괴적 변경이라 2.0.0으로 분리했다(공유 모듈이라
  # in-place 수정 시 develop/production의 다음 plan에서 ArgoCD/LBC가 destroy→recreate됨 —
  # docs/terraform-principles.md "커스텀 모듈 — 디렉토리 기반 버전 관리" 참조).
  # develop/production은 각자 LBC/ArgoCD GitOps 이관(state mv/rm)을 마친 뒤 이 경로로 전환한다.
  source = "../../../../../modules/eks-addons/2.0.0"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn
  vpc_id            = local.vpc_id

  # [WHY — *_config 객체로 통째로 넘기는 이유]
  # 모듈은 enable_*(켜고 끄기)만 알고, chart_version/role_name/role_name_use_prefix 등
  # 그 addon의 나머지 설정은 전부 이 root가 객체로 조립해 넘긴다 — 정책이 바뀌면 이 파일만
  # 고치면 되고 공유 모듈(modules/eks-addons/2.0.0)은 안 건드린다. 재사용 가능한 Terraform
  # 모듈에서 흔히 쓰는 pass-through 패턴과 동일. 상세 이유는
  # modules/eks-addons/2.0.0/variables.tf의 lbc_config 등 WHY 참고.
  enable_aws_load_balancer_controller = local.eks_addons.enable_aws_load_balancer_controller
  lbc_config = {
    chart_version        = local.eks_addons.lbc_chart_version
    role_name            = "${local.cluster_name}-lbc-irsa"
    role_name_use_prefix = false
  }

  enable_external_dns            = local.eks_addons.enable_external_dns
  external_dns_route53_zone_arns = local.eks_addons.external_dns_route53_zone_arns
  external_dns_config = {
    chart_version        = local.eks_addons.external_dns_chart_version
    role_name            = "${local.cluster_name}-external-dns-irsa"
    role_name_use_prefix = false
  }
  # monitoring 클러스터: pyhtest.com zone이 workload 계정에 있으므로 크로스 계정 Role 필요
  external_dns_assume_role_arn = local.external_dns_cross_account_role_arn

  enable_karpenter = local.eks_addons.enable_karpenter
  karpenter_config = {
    chart_version          = local.eks_addons.karpenter_chart_version
    role_name              = "${local.cluster_name}-karpenter-controller-irsa"
    role_name_use_prefix   = false
    policy_name            = "${local.cluster_name}-karpenter-controller-irsa"
    policy_name_use_prefix = false
    # policy_statements(EC2 Spot service-linked-role fix)는 넣지 않는다 — 모듈이 정합성
    # fix로 항상 강제 병합한다(modules/eks-addons/2.0.0/variables.tf의 karpenter_config
    # WHY 참고). 여기서 추가 정책이 필요해지면 이 키에 넣으면 된다(concat으로 합쳐짐).
  }
  karpenter_node_config = {
    iam_role_name            = "${local.cluster_name}-karpenter-node"
    iam_role_use_name_prefix = false
  }
  karpenter_sqs_config = {
    queue_name = "${local.cluster_name}-karpenter"
  }

  enable_external_secrets             = local.eks_addons.enable_external_secrets
  external_secrets_ssm_parameter_arns = local.eks_addons.external_secrets_ssm_parameter_arns
  external_secrets_kms_key_arns       = local.eks_addons.external_secrets_kms_key_arns
  external_secrets_config = {
    chart_version        = local.eks_addons.external_secrets_chart_version
    role_name            = "${local.cluster_name}-external-secrets-irsa"
    role_name_use_prefix = false
  }

  enable_argocd                      = local.eks_addons.enable_argocd
  argocd_chart_version               = local.eks_addons.argocd_chart_version
  argocd_ha_enabled                  = local.eks_addons.argocd_ha_enabled
  argocd_ingress_enabled             = local.eks_addons.argocd_ingress_enabled
  argocd_ingress_hostname            = local.eks_addons.argocd_ingress_hostname
  argocd_ingress_acm_certificate_arn = local.acm_certificate_arn
  argocd_ingress_allowed_cidrs       = local.eks_addons.argocd_ingress_allowed_cidrs
  argocd_ingress_alb_name            = local.eks_addons.argocd_ingress_alb_name
  argocd_admin_password_bcrypt       = local.eks_addons.argocd_admin_password_bcrypt
  argocd_admin_password_mtime        = local.eks_addons.argocd_admin_password_mtime

  argocd_notifications_slack_enabled = local.eks_addons.argocd_notifications_slack_enabled
  # GitOps Bridge Hub: ArgoCD application-controller가 다른 클러스터를 크로스 계정으로
  # 관리할 때 assume하는 IRSA Role ARN(gitops-bridge-irsa.tf 참조). 다른
  # local.eks_addons.xxx 참조와 달리 이 값은 리터럴이 아니라 같은 root의 다른 리소스 참조다.
  argocd_controller_irsa_role_arn = aws_iam_role.argocd_application_controller.arn

  # Argo Rollouts는 Terraform이 전혀 관여하지 않는 addon(devops-manifest의 ArgoCD Application이
  # 전담)이라, 이 모듈은 "클러스터에 실제로 있는가"를 알 방법이 없다 — ArgoCD UI의
  # rollout-extension을 계속 켜두려면 root가 직접 true를 명시해야 한다
  # (modules/eks-addons/2.0.0/variables.tf의 argo_rollouts_extension_enabled 참조).
  argo_rollouts_extension_enabled = true

  # monitoring 클러스터는 OTel Hub — spoke collector 미설치
  enable_otel_spoke_collector = local.eks_addons.enable_otel_spoke_collector

  # GitOps Bridge Hub: monitoring이 자기 자신을 spoke로 명시 등록하는 cluster Secret +
  # App-of-Apps 부트스트랩. develop/production은 이 변수를 안 넘기면(기본값 null) spoke로
  # 동작한다 — locals.tf의 local.gitops_bridge_hub_cluster 상단 WHY 참고.
  #
  # [WHY — apps.addons가 devops-manifest의 실제 addon 매니페스트가 아닌 이유]
  # bootstrap/root-app-addons.yaml은 devops-manifest 저장소의 repoURL·path·targetRevision을
  # 가리키는 "포인터" ApplicationSet이다 — devops-manifest(private repo)의 실제 콘텐츠는 이
  # root가 file()로도, 다른 어떤 방식으로도 읽지 않는다. 실제 fetch는 이 Application이
  # 클러스터에 생성된 뒤 ArgoCD 자신의 git credential로 수행한다 — 그래서
  # docs/addon-strategy.md의 "이 저장소가 devops-manifest를 직접 읽지 않는다" 경계가 지켜진다.
  # gitops-bridge-dev/gitops-bridge 공식 예제(getting-started, complete, multi-cluster/hub-spoke)가
  # bootstrap/addons.yaml을 정확히 이 패턴으로 쓴다.
  #
  # repoURL/path/revision 자체는 bootstrap/root-app-addons.yaml에 하드코딩돼 있다 —
  # 이 ApplicationSet은 selector가 Hub 자신에게만 매칭되는 인스턴스 1개뿐이라 클러스터마다
  # 달라질 값이 아니고, AWS 리소스 output도 아닌 정적 컨벤션이라 cluster Secret annotation
  # 브릿지로 전달할 이유가 없다(그 파일 자체의 주석 참고). '{{}}' 템플릿 치환은 Application이
  # 아니라 ApplicationSet(+ generators.clusters)에서만 동작하므로 ApplicationSet으로
  # 작성했다 — selector로 Hub 자신(cluster_name=local.cluster_name)에만 매칭시켜 dev/prd
  # spoke까지 매칭돼 중복 생성되는 걸 막는다(bootstrap/root-app-addons.yaml 자체의 주석 참고).
  # devops-manifest의 argocd/root-app-addons.yaml 원본은 삭제되어 이 로컬 사본이 유일한
  # source of truth다.
  #
  # [WHY — file()이 아니라 templatefile()인 이유] bootstrap/root-app-addons.yaml의 selector가
  # Hub 자신의 cluster_name(local.cluster_name, 예: eks-practice-mon)을 정확히 알아야 한다.
  # YAML 안에 값을 리터럴로 박아두면 Hub가 재생성돼 이름이 바뀔 일은 없지만("$
  # {project}${name_suffix}" 결정론적 조합) 그래도 이 root의 다른 모든 값(role_name 등)과
  # 동일하게 root가 소유한 local.cluster_name 하나를 유일한 source of truth로 유지하기 위해
  # 템플릿 변수로 주입한다 — YAML의 '{{...}}'(ArgoCD Go 템플릿)와 Terraform의 '${...}'는
  # 서로 다른 문법이라 충돌하지 않는다.
  #
  # [WHY — workload(catalog/gateway/order) Application은 여기서 부트스트랩하지 않는 이유]
  # addon(LBC·karpenter·external-dns 등)은 "클러스터가 쓸 수 있는 상태인가"의 일부라 인프라
  # 프로비저닝과 자연스럽게 묶이지만, 실제 서비스 배포는 앱 팀·CI/CD가 결정할 별도 라이프사이클
  # 이다 — monitoring Terraform apply가 트리거할 일이 아니다. vendor 예제도 이 둘을 항상 묶지는
  # 않는다(multi-cluster/hub-spoke는 addons+workloads를 같이 부트스트랩하지만
  # multi-cluster/hub-spoke-shared는 addons만 부트스트랩). workload 부트스트랩 방식은
  # 별도 단계에서 결정한다.
  gitops_bridge_hub = {
    cluster = local.gitops_bridge_hub_cluster
    apps = {
      addons = templatefile("${path.module}/bootstrap/root-app-addons.yaml", {
        cluster_name = local.cluster_name
      })
    }
  }

  replica_counts  = local.replica_counts
  additional_tags = local.common_tags
}

# ExternalDNS IRSA Role에 크로스 계정 assume 권한 추가
#
# blueprints가 생성한 ExternalDNS IRSA Role은 동일 계정 Route53만 접근 가능하다.
# monitoring → workload 계정 Route53 접근을 위해 sts:AssumeRole 인라인 정책을 추가한다.
# Role 이름 패턴: {cluster_name}-external-dns-irsa (modules/eks-addons CLAUDE.md 참조)
#
# external_dns_cross_account_role_arn = "" (최초 부트스트랩 1단계)인 경우 이 리소스를 생성하지 않는다.
# external-dns-cross-account-role apply 후 3단계 재apply 시 count=1로 전환되어 정책이 추가된다.
moved {
  from = aws_iam_role_policy.external_dns_assume_route53_delegation
  to   = aws_iam_role_policy.external_dns_assume_cross_account_role
}

resource "aws_iam_role_policy" "external_dns_assume_cross_account_role" {
  count = local.external_dns_cross_account_role_arn != "" ? 1 : 0

  name = "assume-external-dns-cross-account-role"
  # IAM Role ARN 마지막 세그먼트 추출 — path 포함 ARN(role/path/name)에서도 정확히 role name만 얻음
  role = regex("[^/]+$", module.eks_addons.external_dns_role_arn)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeExternalDnsCrossAccountRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = local.external_dns_cross_account_role_arn
      }
    ]
  })
}

# aws-parameterstore ClusterSecretStore — GitOps Bridge(Phase 6-4)로 이관 완료.
# eks-practice-devops-manifest 저장소의 ArgoCD Application이 관리한다. IAM Role
# (external-secrets-sa IRSA, modules/eks-addons가 blueprints를 통해 생성)은 계속
# Terraform이 관리한다. 판단 기준은 docs/addon-strategy.md "GitOps 관리 경계" 참조.

# [WHY — ExternalSecret(ESO) 대신 Terraform이 SSM을 직접 읽어 Secret을 만드는 이유]
# ClusterSecretStore/ExternalSecret은 ESO가 설치하는 CRD라, 이 repo-creds Secret을 그
# 경로로 만들면 "완전 재구축" 시나리오에서 순환 의존이 생긴다:
#   1. ArgoCD가 devops-manifest를 sync하려면 이 repo-creds Secret이 필요
#   2. 그 Secret은 ExternalSecret(ESO CRD)이 만듦 → ESO의 CRD+controller가 먼저 떠 있어야 함
#   3. ESO 자신도 GitOps(devops-manifest)로 관리하는데, ESO를 설치하려면 ArgoCD가
#      devops-manifest를 먼저 읽어야 하고, 그러려면 1번의 Secret이 필요 → 순환
# 그래서 ESO(ExternalSecret)를 완전히 우회하고 Terraform이 SSM에서 직접 값을 읽어(아래
# data 블록) 평범한 K8s Secret으로 만든다 — 이러면 ESO 존재 여부와 무관하게 이 Secret은
# 항상 먼저 존재하고, ArgoCD 부트스트랩이 ESO에 의존하지 않는다.
# Image Updater의 git-creds(아래 argocd_image_updater_git_creds)는 이 순환에 해당하지
# 않는다 — Image Updater는 ArgoCD가 이미 떠 있어야 동작하는 컴포넌트라 의존 방향이 반대다.
# 그래서 그쪽은 계속 ESO(ExternalSecret)를 그대로 쓴다.
#
# ArgoCD 공식 repo-creds Secret 스펙(argocd.argoproj.io/secret-type: repo-creds 라벨 +
# type/url/githubAppID/githubAppInstallationID/githubAppPrivateKey 키)을 그대로 따른다.
# https://argo-cd.readthedocs.io/en/stable/operator-manual/argocd-repo-creds-yaml/
data "aws_ssm_parameter" "argocd_github_app_id" {
  name            = "/eks-practice/monitoring/argocd/github-app/app-id"
  with_decryption = true
}

data "aws_ssm_parameter" "argocd_github_app_installation_id" {
  name            = "/eks-practice/monitoring/argocd/github-app/installation-id"
  with_decryption = true
}

data "aws_ssm_parameter" "argocd_github_app_private_key" {
  name            = "/eks-practice/monitoring/argocd/github-app/private-key"
  with_decryption = true
}

resource "kubernetes_secret_v1" "argocd_github_app_repo_creds" {
  metadata {
    name      = "argocd-github-app-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  data = {
    type                    = "git"
    url                     = "https://github.com/hul0810"
    githubAppID             = data.aws_ssm_parameter.argocd_github_app_id.value
    githubAppInstallationID = data.aws_ssm_parameter.argocd_github_app_installation_id.value
    githubAppPrivateKey     = data.aws_ssm_parameter.argocd_github_app_private_key.value
  }

  type = "Opaque"

  depends_on = [module.eks_addons]
}

# ArgoCD Image Updater의 GitHub App git-creds(ExternalSecret) — GitOps Bridge(Phase 6-4)로
# 이관 완료. eks-practice-devops-manifest 저장소의 ArgoCD Application이 관리한다.
