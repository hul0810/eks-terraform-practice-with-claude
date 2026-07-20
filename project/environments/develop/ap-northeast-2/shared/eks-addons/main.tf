################################################################################
# Phase 6-5: modules/eks-addons 1.0.0 → 2.0.0 전환
#
# LBC/Karpenter/ExternalDNS/ExternalSecrets의 Helm 관리 주체를 Terraform에서
# ArgoCD(devops-manifest)로 이관 완료한 뒤(sync 검증 — TODO_LIST.md Task 9) 전환한다.
# IAM(IRSA Role/Policy, Karpenter 노드 Role/SQS/EventBridge)은 이 모듈이 계속 관리하고,
# Helm release만 ArgoCD로 넘어간다 — modules/eks-addons/2.0.0/CLAUDE.md
# "GitOps Bridge: 모듈 인스턴스 구성" 절 참조.
#
# 이 source 전환과 동시에 terraform state mv/rm으로 기존 module.eks_blueprints_addons
# 하위 IAM 리소스를 module.eks_blueprints_addons_gitops로 옮기고, helm_release는
# state rm으로 추적만 제거했다(실제 AWS 리소스 불변, destroy 없음).
#
# monitoring/environments/ap-northeast-2/shared/eks-addons/main.tf와 달리 dev는:
# - gitops_bridge_hub를 넘기지 않는다(기본값 null) — dev는 Hub가 아니라 spoke
#   (monitoring의 gitops-bridge-spokes.tf가 dev를 spoke로 별도 등록한다)
# - external_dns_assume_role_arn 불필요 — Route53 zone이 같은 워크로드 계정에 있음
# - argo_rollouts_extension_enabled=false — dev는 자체 ArgoCD를 운용하지 않음(enable_argocd=false)
################################################################################

module "eks_addons" {
  source = "../../../../../../modules/eks-addons/2.0.0"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn
  vpc_id            = local.vpc_id

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

  enable_karpenter = local.eks_addons.enable_karpenter
  karpenter_config = {
    chart_version          = local.eks_addons.karpenter_chart_version
    role_name              = "${local.cluster_name}-karpenter-controller-irsa"
    role_name_use_prefix   = false
    policy_name            = "${local.cluster_name}-karpenter-controller-irsa"
    policy_name_use_prefix = false
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
  argocd_ingress_alb_name            = local.eks_addons.argocd_ingress_alb_name
  argocd_ingress_acm_certificate_arn = local.acm_certificate_arn
  argocd_ingress_allowed_cidrs       = local.eks_addons.argocd_ingress_allowed_cidrs
  argocd_admin_password_bcrypt       = local.eks_addons.argocd_admin_password_bcrypt
  argocd_admin_password_mtime        = local.eks_addons.argocd_admin_password_mtime

  # dev는 자체 ArgoCD를 운용하지 않는다(enable_argocd=false) — UI extension도 해당 없음.
  argo_rollouts_extension_enabled = false

  enable_otel_spoke_collector       = local.eks_addons.enable_otel_spoke_collector
  otel_gateway_endpoint             = local.eks_addons.otel_gateway_endpoint
  otel_spoke_operator_chart_version = local.eks_addons.otel_spoke_operator_chart_version

  # replica_counts는 넘기지 않는다(기본값 {}) — 2.0.0의 replica_counts는 argocd_server만
  # 받는 strict object 타입이고, dev는 enable_argocd=false라 ArgoCD 자체를 안 켠다.
  additional_tags = local.common_tags
}
