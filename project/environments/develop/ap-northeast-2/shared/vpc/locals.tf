locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc = {
    name               = "${local.project}${local.name_suffix}"
    cidr               = "10.10.0.0/16"
    azs                = data.aws_availability_zones.available.names
    public_subnets     = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
    private_subnets    = ["10.10.32.0/19", "10.10.64.0/19", "10.10.96.0/19", "10.10.128.0/19"]
    database_subnets   = ["10.10.4.0/24", "10.10.5.0/24", "10.10.6.0/24", "10.10.7.0/24"]
    tgw_subnets        = ["10.10.8.0/28", "10.10.8.16/28", "10.10.8.32/28", "10.10.8.48/28"]
    enable_nat_gateway = true
    single_nat_gateway = true # 비용 우선: 단일 NAT GW 구성 (HA 정책 예외 — CLAUDE.md 비용 예외 항목 참조)
    # Karpenter가 프라이빗 서브넷을 자동 탐색할 수 있도록 클러스터 이름 태그를 부여한다.
    # eks/locals.tf의 cluster_name과 동일한 패턴으로 생성하여 하드코딩 불일치를 방지한다.
    cluster_name = "${local.project}${local.name_suffix}"
    additional_tags = {
      Name = "${local.project}${local.name_suffix}"
    }
  }
}
