terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
  }

  backend "s3" {
    bucket       = "eks-practice-tfstate-workload"
    key          = "project/global/ap-northeast-2/route53-delegation/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "terraform-workload"
    use_lockfile = true
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform-workload"

  tag_policy_compliance = "error"

  default_tags {
    tags = local.common_tags
  }
}
