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
    role_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:role/TerraformExecutionRole"
  }

  # Organizations 정책 report_required_tag_for 리소스 타입에서 태그 키 누락 시 plan 차단.
  # 태그 값 유효성 검사는 main.tf의 validate_tags precondition이 담당.
  tag_policy_compliance = "error"

  default_tags {
    tags = local.common_tags
  }
}
