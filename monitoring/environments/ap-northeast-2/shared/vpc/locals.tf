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

  vpc = {
    name = "${local.project}${local.name_suffix}"
    cidr = "10.12.0.0/16"
    # Phase 9: 이 CIDR은 Intra AWS 계정의 monitoring VPC와 동일하게 유지 → TGW 전환 시 재설계 불필요
    azs                = data.aws_availability_zones.available.names
    public_subnets     = ["10.12.0.0/24", "10.12.1.0/24", "10.12.2.0/24", "10.12.3.0/24"]
    private_subnets    = ["10.12.32.0/19", "10.12.64.0/19", "10.12.96.0/19", "10.12.128.0/19"]
    database_subnets   = ["10.12.4.0/24", "10.12.5.0/24", "10.12.6.0/24", "10.12.7.0/24"]
    tgw_subnets        = ["10.12.8.0/28", "10.12.8.16/28", "10.12.8.32/28", "10.12.8.48/28"]
    enable_nat_gateway = false
    single_nat_gateway = true
    cluster_name       = "${local.project}${local.name_suffix}"
    additional_tags = {
      Name = "${local.project}${local.name_suffix}"
    }
  }
}
