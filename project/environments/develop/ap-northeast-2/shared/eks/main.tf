# 태그 값 유효성 검사: Organizations 정책의 허용값을 remote state에서 읽어 검증한다.
# 허용값 변경은 global/tag-policy/main.tf만 수정하면 된다.
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
  }
}

module "eks" {
  source = "../../../../../../modules/eks/1.0.0"

  cluster_name       = local.eks.cluster_name
  kubernetes_version = local.eks.kubernetes_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  endpoint_public_access = local.eks.endpoint_public_access
  public_access_cidrs    = local.eks.public_access_cidrs
  enabled_log_types      = local.eks.enabled_log_types

  system_node_instance_types = local.eks.system_node.instance_types
  system_node_ami_type       = local.eks.system_node.ami_type
  system_node_min_size       = local.eks.system_node.min_size
  system_node_max_size       = local.eks.system_node.max_size
  system_node_desired_size   = local.eks.system_node.desired_size
}
