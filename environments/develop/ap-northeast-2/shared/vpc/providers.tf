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
  profile = "terraform"

  assume_role {
    role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
  }

  # AWS Organizations Tag Policy의 필수 태그 요구사항을 plan 단계에서 검증.
  # 태그 누락 시 apply 전에 즉시 실패. AWS Provider v6.22.0+ 필요.
  tag_policy_compliance = "error"

  default_tags {
    tags = local.common_tags
  }
}
