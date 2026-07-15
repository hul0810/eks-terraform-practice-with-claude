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
  source = "../../../../../modules/eks-addons/1.0.0"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn
  vpc_id            = local.vpc_id

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

  # monitoring 클러스터는 OTel Hub — spoke collector 미설치
  enable_otel_spoke_collector = local.eks_addons.enable_otel_spoke_collector

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

# ── ClusterSecretStore — AWS Parameter Store 연결 (ESO, GitHub App/Image Updater 전용) ──
#
# SSM Parameter Store(SecureString)에 등록된 시크릿을 External Secrets Operator(ESO)로
# 읽어오기 위한 ClusterSecretStore다. ArgoCD GitHub App 인증 정보(아래 repo-creds,
# Image Updater git-creds) 전용이다.
#
# [이력 — 한때 Slack Bot Token도 함께 서빙했다가 다시 좁힌 이유]
# Argo Rollouts/ArgoCD Notifications의 Slack Bot Token ExternalSecret이 한때 이 Store를
# conditions.namespaces=["argocd","argo-rollouts"]로 확장해 공유했으나, 보안 리뷰에서
# 이 Store 뒤 IAM Role이 GitHub App Private Key(조직 전체 저장소 쓰기 권한) 경로까지
# 읽을 수 있어 argo-rollouts 네임스페이스의 ExternalSecret이 그 경로를 remoteRef로
# 지정하면 그대로 읽어갈 수 있는 문제가 지적되어, Slack Bot Token 전용 신뢰 경계
# (notifications-irsa.tf)로 분리했다. 상세 사유는 notifications-irsa.tf 상단 주석 참조.
#
# [왜 GitOps(devops-manifest 저장소)가 아니라 Terraform이 이 리소스를 관리하는가]
# ArgoCD 자신의 부트스트랩에 필요한 리소스(순환 의존성)이기 때문이다.
# 일반 원칙과 판단 기준은 docs/addon-strategy.md "GitOps 관리 경계" 참조.
#
# [ClusterSecretStore를 선택한 이유 — 크로스 네임스페이스 ServiceAccount 참조]
# ESO controller의 ServiceAccount(external-secrets-sa)는 external-secrets 네임스페이스에 있고
# IRSA Role 신뢰 정책의 OIDC sub 조건이 system:serviceaccount:external-secrets:external-secrets-sa로
# 고정되어 있다(modules/eks-addons가 blueprints를 통해 생성 — 수동 변경 금지 대상).
# 반면 이 Store를 참조하는 Secret들은 argocd·argo-rollouts 등 다른 네임스페이스에 생성되어야 한다.
#
# 네임스페이스 스코프의 SecretStore는 spec.provider.aws.auth.jwt.serviceAccountRef.namespace를
# 무시하고 항상 SecretStore 자신과 같은 네임스페이스의 ServiceAccount만 참조할 수 있다
# (공식 이슈: external-secrets/external-secrets#366 "Enable Auth.JWTAuth.ServiceAccountRef.Namespace
# in kind SecretStore" — 아직 미지원). ClusterSecretStore는 클러스터 스코프라 이 제약이 없고
# serviceAccountRef.namespace를 그대로 존중한다(공식 문서: https://external-secrets.io/latest/api/clustersecretstore/).
# 따라서 IAM Role 신뢰 정책을 건드리지 않고도 크로스 네임스페이스 참조가 가능한
# ClusterSecretStore를 사용한다.
#
# [리소스 이름 변경 — moved 블록]
# 이 리소스는 원래 ArgoCD GitHub App 전용으로 만들어져 argocd_github_app_secret_store로
# 명명되었으나, Argo Rollouts Slack Bot Token도 함께 서빙하도록 스코프가 넓어지면서
# 이름이 더 이상 실체를 반영하지 못한다. kubernetes_manifest는 K8s 오브젝트 identity
# (apiVersion/kind/metadata.name)로 식별되고 metadata.name(aws-parameterstore)은 그대로
# 유지되므로, Terraform 리소스 라벨만 옮기는 이 변경은 재생성을 유발하지 않는다.
moved {
  from = kubernetes_manifest.argocd_github_app_secret_store
  to   = kubernetes_manifest.aws_parameterstore_secret_store
}

resource "kubernetes_manifest" "aws_parameterstore_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-parameterstore"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = "ap-northeast-2"
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets-sa"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
      # conditions.namespaces는 "어느 네임스페이스가 이 Store를 아예 참조 시도할 수
      # 있는가"만 제한하는 defense-in-depth 계층이다(예: default/kube-system 등 무관한
      # 네임스페이스의 시도 자체를 차단). 실제 어떤 SSM 경로를 읽을 수 있는지는 이 Store를
      # 쓰는 모든 네임스페이스가 공유하는 IAM 정책(external_secrets_ssm_parameter_arns,
      # 이 파일 상단 module.eks_addons 호출부 참조)이 결정한다 — 이 목록만으로는
      # GitHub App Private Key에 대한 실제 접근을 네임스페이스별로 격리하지 못한다.
      # argo-rollouts는 더 이상 이 Store를 쓰지 않는다(notifications-irsa.tf로 분리).
      conditions = [
        { namespaces = ["argocd"] }
      ]
    }
  }

  depends_on = [module.eks_addons]
}

# ArgoCD 공식 repo-creds Secret 스펙(argocd.argoproj.io/secret-type: repo-creds 라벨 +
# type/url/githubAppID/githubAppInstallationID/githubAppPrivateKey 키)을 그대로 따른다.
# https://argo-cd.readthedocs.io/en/stable/operator-manual/argocd-repo-creds-yaml/
#
# [template.mergePolicy = Merge를 사용하는 이유]
# ESO는 target.template이 설정되면 기본적으로 template에서 참조하지 않은 spec.data 키를
# 결과 Secret에서 제외한다(https://external-secrets.io/latest/guides/templating/).
# mergePolicy: Merge로 전환하면 template.data의 리터럴 값(type, url)과 spec.data로 가져온
# 키(githubAppID 등, secretKey를 최종 Secret 키 이름과 동일하게 지정)가 함께 병합된다.
resource "kubernetes_manifest" "argocd_github_app_repo_creds" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "argocd-github-app-repo-creds"
      namespace = "argocd"
    }
    spec = {
      secretStoreRef = {
        name = kubernetes_manifest.aws_parameterstore_secret_store.manifest.metadata.name
        kind = "ClusterSecretStore"
      }
      refreshInterval = "1h"
      target = {
        name           = "argocd-github-app-repo-creds"
        creationPolicy = "Owner"
        template = {
          mergePolicy = "Merge"
          metadata = {
            labels = {
              "argocd.argoproj.io/secret-type" = "repo-creds"
            }
          }
          data = {
            type = "git"
            url  = "https://github.com/hul0810"
          }
        }
      }
      data = [
        {
          secretKey = "githubAppID"
          remoteRef = { key = "/eks-practice/monitoring/argocd/github-app/app-id" }
        },
        {
          secretKey = "githubAppInstallationID"
          remoteRef = { key = "/eks-practice/monitoring/argocd/github-app/installation-id" }
        },
        {
          secretKey = "githubAppPrivateKey"
          remoteRef = { key = "/eks-practice/monitoring/argocd/github-app/private-key" }
        },
      ]
    }
  }

  depends_on = [
    module.eks_addons,
    kubernetes_manifest.aws_parameterstore_secret_store,
  ]
}

# ArgoCD Image Updater가 이미지 태그 갱신 커밋에 사용할 GitHub App 인증 정보.
# argocd-github-app-repo-creds(ArgoCD 레포 접근, 조직 전체 읽기 전용)와는 별도 GitHub App —
# Image Updater는 매니페스트 저장소에 커밋(쓰기)해야 하므로 권한 범위가 다르다.
#
# [repo-creds와 달리 argocd.argoproj.io/secret-type 라벨이 불필요한 이유]
# argocd-github-app-repo-creds는 ArgoCD server가 "repo-creds"로 라벨링된 Secret을 자동으로
# 스캔해 레포 인증에 쓴다(ArgoCD 자체 컨벤션). Image Updater는 그런 자동 탐색 없이
# Application(또는 전역 config)의 git.credentials 설정에서 Secret 이름을 직접 참조하므로,
# 이 라벨도 template/mergePolicy도 필요 없다 — 3개 키를 그대로 담은 평범한 Secret이면 충분하다.
resource "kubernetes_manifest" "argocd_image_updater_git_creds" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "argocd-image-updater-git-creds"
      namespace = "argocd"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = kubernetes_manifest.aws_parameterstore_secret_store.manifest.metadata.name
      }
      target = {
        name           = "argocd-image-updater-git-creds"
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
      }
      data = [
        {
          secretKey = "githubAppID"
          remoteRef = { key = "/eks-practice/monitoring/argocd-image-updater/app-id" }
        },
        {
          secretKey = "githubAppInstallationID"
          remoteRef = { key = "/eks-practice/monitoring/argocd-image-updater/installation-id" }
        },
        {
          secretKey = "githubAppPrivateKey"
          remoteRef = { key = "/eks-practice/monitoring/argocd-image-updater/private-key" }
        },
      ]
    }
  }

  depends_on = [
    module.eks_addons,
    kubernetes_manifest.aws_parameterstore_secret_store,
  ]
}
