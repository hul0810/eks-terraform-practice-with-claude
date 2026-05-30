module "eks" {
  source = "../../../../../modules/eks/1.0.0"

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
