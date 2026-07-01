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

  enable_argo_rollouts        = local.eks_addons.enable_argo_rollouts
  argo_rollouts_chart_version = null

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
