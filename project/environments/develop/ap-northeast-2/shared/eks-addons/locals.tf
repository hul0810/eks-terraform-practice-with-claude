locals {
  environment = "develop"
  project     = "eks-practice"

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # eks/ state에서 참조하는 클러스터 정보
  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.eks.outputs.cluster_endpoint
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn

  # eks/locals.tf의 kubernetes_version과 동기화 — EKS 버전 업그레이드 시 함께 변경한다
  cluster_version = "1.33"

  eks_addons = {
    # 2026-06-05 기준 최신 stable 버전
    # 버전 업그레이드: helm repo update && helm search repo <chart> --versions
    lbc_chart_version          = "3.4.0"
    external_dns_chart_version = "1.14.5"
    metrics_server_chart_version = "3.12.2"
    karpenter_chart_version    = "1.3.3"

    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    # develop 환경: 빈 리스트 허용 (전체 zone 접근). production은 특정 ARN 명시 필수
    external_dns_route53_zone_arns      = []
    enable_metrics_server               = true
    enable_karpenter                    = true
  }
}
