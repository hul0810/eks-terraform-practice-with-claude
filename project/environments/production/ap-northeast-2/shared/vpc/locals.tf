locals {
  environment = "production"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  # production은 environment_short를 빈 문자열로 두어 구분자까지 완전히 제거한다.
  environment_short = ""
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc = {
    name               = "${local.project}${local.name_suffix}"
    cidr               = "10.11.0.0/16"
    azs                = data.aws_availability_zones.available.names
    public_subnets     = ["10.11.0.0/24", "10.11.1.0/24", "10.11.2.0/24", "10.11.3.0/24"]
    private_subnets    = ["10.11.32.0/19", "10.11.64.0/19", "10.11.96.0/19", "10.11.128.0/19"]
    database_subnets   = ["10.11.4.0/24", "10.11.5.0/24", "10.11.6.0/24", "10.11.7.0/24"]
    tgw_subnets        = ["10.11.8.0/28", "10.11.8.16/28", "10.11.8.32/28", "10.11.8.48/28"]
    enable_nat_gateway = false
    # 비용 우선: 단일 NAT GW 구성 (dev와 동일, HA 정책 예외 — CLAUDE.md 비용 예외 항목 참조)
    # HA 복원 시: single_nat_gateway = false 로 변경 → AZ당 NAT GW 1개 (AZ 장애 시 다른 AZ 아웃바운드 통신 영향 차단)
    single_nat_gateway = true
    # Karpenter가 프라이빗 서브넷을 자동 탐색할 수 있도록 클러스터 이름 태그를 부여한다.
    # eks/locals.tf의 cluster_name과 동일한 패턴으로 생성하여 하드코딩 불일치를 방지한다.
    cluster_name = "${local.project}${local.name_suffix}"
    additional_tags = {
      Name = "${local.project}${local.name_suffix}"
    }
  }
}
