terraform {
  required_version = "~> 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    # terraform-aws-modules/eks v21.x 가 OIDC Provider 지문 계산에 내부적으로 사용
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # terraform-aws-modules/eks v21.x 가 일부 리소스 타이밍 제어에 내부적으로 사용
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform"
  assume_role {
    role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
  }
  default_tags {
    tags = {
      environment = "develop"
      managed_by  = "terraform"
    }
  }
}
