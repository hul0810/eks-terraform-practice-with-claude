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

  # eks/locals.tf의 kubernetes_version과 동기화
  cluster_version = "1.34"

  # monitoring: 단일 시스템 노드(비용 절감)로 모든 애드온 replica=1
  replica_counts = {
    lbc            = 1
    karpenter      = 1
    external_dns   = 1
    metrics_server = 1
    argo_rollouts  = 1
  }

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전
    lbc_chart_version            = "3.4.0"
    external_dns_chart_version   = "1.14.5"
    metrics_server_chart_version = "3.12.2"
    karpenter_chart_version      = "1.12.1"

    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    external_dns_route53_zone_arns      = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.pyhtest.zone_id}"]
    enable_metrics_server               = true
    enable_karpenter                    = true

    # monitoring 클러스터는 OTel의 Hub이므로 spoke collector를 설치하지 않는다.
    # OTel Operator와 Gateway는 observability/ root module에서 관리한다.
    enable_otel_spoke_collector = false

    # ArgoCD: monitoring 클러스터에는 미설치.
    # dev/prd 클러스터의 ArgoCD가 Phase 6에서 monitoring 클러스터의 obserbability 스택을 관리한다.
    enable_argocd        = false
    enable_argo_rollouts = false
    argocd_chart_version = "9.5.21"
  }

  karpenter_node_pools = {
    general = {
      capacity_types    = ["spot", "on-demand"]
      instance_families = ["c", "m", "r"]
      architectures     = ["amd64"]
      instance_gen_min  = "2"
      weight            = 10
      taints            = []
      limits            = { cpu = "50", memory = "200Gi" }
    }
  }
}
