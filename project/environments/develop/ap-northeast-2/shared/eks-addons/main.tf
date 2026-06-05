module "eks_addons" {
  source = "../../../../../../modules/eks-addons/1.0.0"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn

  addon_versions      = local.eks_addons.addon_versions
  enable_external_dns = local.eks_addons.enable_external_dns
  lbc_chart_version   = local.eks_addons.lbc_chart_version

  additional_tags = local.common_tags
}
