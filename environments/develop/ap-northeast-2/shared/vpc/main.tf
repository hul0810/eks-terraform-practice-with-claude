module "vpc" {
  source = "../../../../../modules/vpc/1.0.0"

  vpc_name           = local.vpc.name
  vpc_cidr           = local.vpc.cidr
  azs                = local.vpc.azs
  public_subnets     = local.vpc.public_subnets
  private_subnets    = local.vpc.private_subnets
  database_subnets   = local.vpc.database_subnets
  tgw_subnets        = local.vpc.tgw_subnets
  enable_nat_gateway = local.vpc.enable_nat_gateway
  single_nat_gateway = local.vpc.single_nat_gateway

  additional_tags = local.vpc.additional_tags
}
