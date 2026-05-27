locals {
  env     = "develop"
  project = "eks-practice"

  vpc = {
    name             = "${local.project}-${local.env}"
    cidr             = "10.10.0.0/16"
    azs              = data.aws_availability_zones.available.names
    public_subnets   = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24"]
    private_subnets  = ["10.10.32.0/19", "10.10.64.0/19", "10.10.96.0/19", "10.10.128.0/19"]
    database_subnets = ["10.10.4.0/24", "10.10.5.0/24", "10.10.6.0/24", "10.10.7.0/24"]
    tgw_subnets      = ["10.10.8.0/28", "10.10.8.16/28", "10.10.8.32/28", "10.10.8.48/28"]
    enable_nat_gateway = false
    single_nat_gateway = true  # NAT GW 활성화 시 단일 NGW 사용 (develop 비용 절감)
  }
}
