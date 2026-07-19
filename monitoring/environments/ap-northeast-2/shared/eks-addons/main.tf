################################################################################
# ⚠️ 첫 배포 또는 Karpenter 재설치 시 2단계 apply 필수
#
#   hashicorp/kubernetes provider의 kubernetes_manifest는 plan 단계에서
#   클러스터 API에 CRD 스키마를 조회하여 manifest를 검증한다.
#   depends_on은 apply 실행 순서만 제어하며 plan-time 검증에는 영향을 주지 않는다.
#   Karpenter CRD가 없는 상태에서 plan을 실행하면 "no matches for kind EC2NodeClass" 에러가 발생한다.
#
#   1단계: terraform apply -target=module.eks_addons
#          → Karpenter Helm chart 설치 → CRD 클러스터 등록
#   2단계: terraform apply
#          → EC2NodeClass / NodePool 생성
################################################################################

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

  # "rest" 인스턴스(eks_blueprints_addons)에 실제로 연결된 addon은 enable_metrics_server/
  # enable_argo_rollouts 2개뿐인데 monitoring은 둘 다 false다 — 즉 이 인스턴스에 Helm으로
  # 설치할 addon이 하나도 안 남았다. modules/eks-addons/2.0.0/CLAUDE.md가 예고한 "남은 addon이
  # 없어지면 이 값을 false로 바꿔 최종 정리" 시점이라 명시적으로 false로 고정한다 — 지금
  # 당장은 no-op이지만(어차피 활성 addon이 없음), 향후 이 인스턴스에 새 addon이 실수로
  # 추가되어도 Helm이 조용히 다시 뜨는 걸 막는 안전장치 역할을 한다.
  create_kubernetes_resources = false

  enable_aws_load_balancer_controller = local.eks_addons.enable_aws_load_balancer_controller
  lbc_chart_version                   = local.eks_addons.lbc_chart_version

  enable_external_dns            = local.eks_addons.enable_external_dns
  external_dns_route53_zone_arns = local.eks_addons.external_dns_route53_zone_arns
  external_dns_chart_version     = local.eks_addons.external_dns_chart_version
  # monitoring 클러스터: pyhtest.com zone이 workload 계정에 있으므로 크로스 계정 Role 필요
  external_dns_assume_role_arn = local.external_dns_cross_account_role_arn

  enable_metrics_server        = local.eks_addons.enable_metrics_server
  metrics_server_chart_version = local.eks_addons.metrics_server_chart_version

  enable_karpenter        = local.eks_addons.enable_karpenter
  karpenter_chart_version = local.eks_addons.karpenter_chart_version

  enable_external_secrets             = local.eks_addons.enable_external_secrets
  external_secrets_chart_version      = local.eks_addons.external_secrets_chart_version
  external_secrets_ssm_parameter_arns = local.eks_addons.external_secrets_ssm_parameter_arns
  external_secrets_kms_key_arns       = local.eks_addons.external_secrets_kms_key_arns

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

  enable_argo_rollouts                      = local.eks_addons.enable_argo_rollouts
  argo_rollouts_chart_version               = local.eks_addons.argo_rollouts_chart_version
  argo_rollouts_notifications_slack_enabled = local.eks_addons.argo_rollouts_notifications_slack_enabled
  argocd_notifications_slack_enabled        = local.eks_addons.argocd_notifications_slack_enabled
  # GitOps Bridge Hub(Phase 6-1): ArgoCD application-controller가 awsAuthConfig로 클러스터를
  # 명시 등록할 때 필요한 IRSA Role ARN. 다른 local.eks_addons.xxx 참조와 달리 이 값은
  # 리터럴이 아니라 같은 root의 다른 리소스 참조다 — notifications_secret_store_argo_rollouts가
  # kubernetes_service_account_v1.notifications_eso_argo_rollouts를 참조하는 것과 같은 방식
  # (gitops-bridge-irsa.tf 참조).
  argocd_controller_irsa_role_arn = aws_iam_role.argocd_application_controller.arn

  # Phase 6-4: Argo Rollouts의 Helm 설치가 ArgoCD로 이관되며 enable_argo_rollouts=false로
  # Terraform이 손을 뗐지만, 클러스터에는 Argo Rollouts가 계속 존재한다(ArgoCD가 관리).
  # 명시하지 않으면 ArgoCD UI의 rollout-extension이 enable_argo_rollouts=false를 따라 조용히
  # 꺼진다 — modules/eks-addons/2.0.0/variables.tf 참조.
  argo_rollouts_extension_enabled = true

  # monitoring 클러스터는 OTel Hub — spoke collector 미설치
  enable_otel_spoke_collector = local.eks_addons.enable_otel_spoke_collector

  # GitOps Bridge Hub(Phase 6-1): monitoring이 자기 자신을 spoke로 명시 등록하는 cluster
  # Secret + (추후) App-of-Apps 데이터. develop/production은 이 변수를 안 넘기면(기본값 null)
  # spoke로 동작한다 — gitops-bridge-irsa.tf의 local.gitops_bridge_hub_cluster 상단 WHY 참고.
  gitops_bridge_hub = {
    cluster = local.gitops_bridge_hub_cluster
    apps    = {}
  }

  replica_counts  = local.replica_counts
  additional_tags = local.common_tags

  # gitops_bridge_hub.cluster에 담긴 IAM Role ARN들이 실제로 유효하려면 Access Entry+RBAC
  # 체인이 먼저 성립해 있어야 한다 — 원래 root가 직접 만들던 kubernetes_secret_v1에 걸려있던
  # depends_on을 이 module 호출로 그대로 옮긴 것이다(gitops-bridge-irsa.tf 참고).
  #
  # [review-terraform 지적 — 이 depends_on의 실제 범위] 이 RBAC 바인딩이 필요한 건 모듈
  # 내부의 gitops_bridge_bootstrap.cluster Secret 하나뿐인데, 모듈 경계상 그 리소스 하나만
  # 겨냥해 depends_on을 줄 방법이 없어 module.eks_addons 전체(Karpenter/LBC/ExternalDNS 등
  # 이 RBAC와 무관한 리소스까지)가 이 뒤로 직렬화된다. 실습 규모에서는 apply 시간 영향이
  # 미미해 감수하지만, 이 RBAC 바인딩을 재생성해야 하는 상황이 생기면 전체 addon apply가
  # 불필요하게 대기한다는 걸 알고 있어야 한다.
  depends_on = [kubernetes_cluster_role_binding.argocd_read_all]
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

################################################################################
# ⚠️ ESO 최초 설치 시 2단계 apply 필수 (Karpenter/OTel과 동일한 제약)
#
#   hashicorp/kubernetes provider의 kubernetes_manifest는 plan 단계에서
#   클러스터 API에 CRD 스키마를 조회하여 manifest를 검증한다. ClusterSecretStore/
#   ExternalSecret CRD는 이 apply의 module.eks_addons(ESO Helm chart)가 설치하므로,
#   depends_on으로 apply 순서는 보장되지만 plan-time 검증에는 영향을 주지 않는다.
#   ESO가 클러스터에 아직 없는 상태(최초 설치, 또는 재설치)에서 plan을 실행하면
#   "no matches for kind ClusterSecretStore/ExternalSecret" 에러가 발생한다.
#
#   1단계: terraform apply -target=module.eks_addons
#          → ESO Helm chart 설치 → CRD 클러스터 등록
#   2단계: terraform apply
#          → ClusterSecretStore / ExternalSecret 생성
################################################################################

# aws-parameterstore ClusterSecretStore — GitOps Bridge(Phase 6-4)로 이관 완료.
# eks-practice-devops-manifest 저장소의 ArgoCD Application이 관리한다. IAM Role
# (external-secrets-sa IRSA, modules/eks-addons가 blueprints를 통해 생성)은 계속
# Terraform이 관리한다. 판단 기준은 docs/addon-strategy.md "GitOps 관리 경계" 참조.

# [정정 — ExternalSecret(ESO) 대신 Terraform이 SSM을 직접 읽어 Secret을 만드는 이유]
# 원래는 위 aws_parameterstore_secret_store(ClusterSecretStore)를 거치는 ExternalSecret이었다.
# 그런데 ClusterSecretStore/ExternalSecret은 ESO가 설치하는 CRD라, "완전 재구축"(클러스터를
# 처음부터 새로 만드는) 시나리오를 가정해보면 순환 의존이 생긴다는 게 뒤늦게 드러났다:
#   1. ArgoCD가 devops-manifest를 sync하려면 이 repo-creds Secret이 필요
#   2. 그 Secret은 ExternalSecret(ESO CRD)이 만듦 → ESO의 CRD+controller가 먼저 떠 있어야 함
#   3. ESO 자신도 GitOps(devops-manifest)로 관리하려는 게 Phase 6-4 계획인데, ESO를 설치하려면
#      ArgoCD가 devops-manifest를 먼저 읽어야 하고, 그러려면 1번의 Secret이 필요 → 순환
# docs/addon-strategy.md "GitOps 관리 경계"의 "ArgoCD 자신의 부트스트랩에 필요한 리소스"
# 원칙은 애초에 ArgoCD Helm 설치뿐 아니라 이 repo-creds Secret에도 동일하게 적용됐어야
# 했다 — ESO(추이 ExternalSecret)를 거치는 한 이 Secret도 사실상 ESO에 종속되어 똑같이
# 순환 의존 사슬에 걸리기 때문이다. 그래서 ESO(ExternalSecret)를 완전히 우회하고 Terraform이
# SSM에서 직접 값을 읽어(아래 data 블록) 평범한 K8s Secret으로 만든다 — 이러면 ESO가 아직
# 없어도(심지어 GitOps로 이관되어 ArgoCD sync 이후에나 설치되어도) 이 Secret은 항상 먼저
# 존재하고, ArgoCD 부트스트랩이 ESO 존재 여부와 완전히 무관해진다.
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
