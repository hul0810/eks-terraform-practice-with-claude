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
    addon_versions = {
      # 버전 조회: aws eks describe-addon-versions --kubernetes-version 1.33 --region ap-northeast-2
      # 2026-06-05 기준 default 버전
      ebs_csi_driver = "v1.60.1-eksbuild.1"
      metrics_server = "v0.8.1-eksbuild.10"
      external_dns   = "v0.21.0-eksbuild.4"
    }

    enable_external_dns = true

    # 2026-06-05 기준 최신 stable 버전
    lbc_chart_version = "3.4.0"
  }
}
