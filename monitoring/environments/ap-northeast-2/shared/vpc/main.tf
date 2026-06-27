resource "terraform_data" "validate_tags" {
  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_environments, local.common_tags.environment)
      error_message = "environment 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_environments)}. 현재 값: '${local.common_tags.environment}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_managed_by, local.common_tags.managed_by)
      error_message = "managed_by 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_managed_by)}. 현재 값: '${local.common_tags.managed_by}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_projects, local.common_tags.project)
      error_message = "project 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_projects)}. 현재 값: '${local.common_tags.project}'"
    }
  }
}

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

  cluster_name    = local.vpc.cluster_name
  additional_tags = local.vpc.additional_tags

}
