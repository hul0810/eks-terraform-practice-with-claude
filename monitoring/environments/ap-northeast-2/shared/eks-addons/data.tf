data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-monitoring"
    key     = "monitoring/ap-northeast-2/shared/eks/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-monitoring"
  }
}

data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-mgmt"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_route53_zone" "pyhtest" {
  name         = "pyhtest.com"
  private_zone = false
}

data "aws_acm_certificate" "pyhtest_wildcard" {
  domain      = "pyhtest.com"
  statuses    = ["ISSUED"]
  key_types   = ["RSA_2048"]
  most_recent = true
}
