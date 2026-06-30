data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
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

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-monitoring"
    key     = "monitoring/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-monitoring"
  }
}
