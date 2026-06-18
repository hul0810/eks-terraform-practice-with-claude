module "eks_addons" {
  source = "../../../../../../modules/eks-addons/1.0.0"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn
  vpc_id            = local.vpc_id

  enable_aws_load_balancer_controller = local.eks_addons.enable_aws_load_balancer_controller
  lbc_chart_version                   = local.eks_addons.lbc_chart_version
  enable_argo_rollouts                = local.eks_addons.enable_argo_rollouts
  argo_rollouts_chart_version         = local.eks_addons.argo_rollouts_chart_version
  enable_external_dns                 = local.eks_addons.enable_external_dns
  external_dns_route53_zone_arns      = local.eks_addons.external_dns_route53_zone_arns
  external_dns_chart_version          = local.eks_addons.external_dns_chart_version
  enable_metrics_server               = local.eks_addons.enable_metrics_server
  metrics_server_chart_version        = local.eks_addons.metrics_server_chart_version
  enable_karpenter                    = local.eks_addons.enable_karpenter
  karpenter_chart_version             = local.eks_addons.karpenter_chart_version
  enable_argocd                       = local.eks_addons.enable_argocd
  argocd_chart_version                = local.eks_addons.argocd_chart_version
  argocd_ha_enabled                   = local.eks_addons.argocd_ha_enabled
  argocd_ingress_enabled              = local.eks_addons.argocd_ingress_enabled
  argocd_ingress_hostname             = local.eks_addons.argocd_ingress_hostname
  argocd_ingress_alb_name             = local.eks_addons.argocd_ingress_alb_name
  argocd_ingress_acm_certificate_arn  = data.aws_acm_certificate.pyhtest_wildcard.arn
  argocd_ingress_allowed_cidrs        = local.eks_addons.argocd_ingress_allowed_cidrs
  argocd_admin_password_bcrypt        = local.eks_addons.argocd_admin_password_bcrypt
  argocd_admin_password_mtime         = local.eks_addons.argocd_admin_password_mtime

  enable_secrets_store_csi_driver        = local.eks_addons.enable_secrets_store_csi_driver
  secrets_store_csi_driver_addon_version = local.eks_addons.secrets_store_csi_driver_addon_version

  replica_counts  = local.replica_counts
  additional_tags = local.common_tags
}
