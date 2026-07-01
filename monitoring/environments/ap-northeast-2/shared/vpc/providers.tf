terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform-monitoring"

  tag_policy_compliance = "error"

  default_tags {
    tags = local.common_tags
  }
}
