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

  enable_metrics_server        = local.eks_addons.enable_metrics_server
  metrics_server_chart_version = local.eks_addons.metrics_server_chart_version

  enable_karpenter        = local.eks_addons.enable_karpenter
  karpenter_chart_version = local.eks_addons.karpenter_chart_version

  # monitoring 클러스터에는 ArgoCD 미설치.
  # hub cluster ArgoCD 전략은 Phase 6에서 결정한다.
  enable_argocd        = local.eks_addons.enable_argocd
  argocd_chart_version = local.eks_addons.argocd_chart_version
  argocd_ha_enabled    = false
  argocd_ingress_enabled = false

  enable_argo_rollouts        = local.eks_addons.enable_argo_rollouts
  argo_rollouts_chart_version = null

  # monitoring 클러스터는 OTel Hub — spoke collector 미설치
  enable_otel_spoke_collector = local.eks_addons.enable_otel_spoke_collector

  replica_counts  = local.replica_counts
  additional_tags = local.common_tags
}
