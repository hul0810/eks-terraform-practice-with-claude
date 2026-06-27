# Terraform 실행자의 IAM 역할의 실제 Role ARN을 조회한다.
# SSO assumed-role 세션에서 issuer_arn은 STS ARN이 아닌 실제 IAM Role ARN을 반환한다.
# EKS access_entries의 principal_arn은 assumed-role 세션이 아닌 IAM Role ARN이어야 한다.
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# 태그 허용값을 Organizations 정책에서 읽어온다. 정책 변경 시 이 파일은 수정하지 않아도 된다.
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-MGMT_ACCOUNT_ID"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

# VPC root module 상태에서 vpc_id, private_subnet_ids 가져옴.
# VPC가 먼저 apply되어 있어야 동작한다.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-WORKLOAD_ACCOUNT_ID"
    key     = "project/production/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}
