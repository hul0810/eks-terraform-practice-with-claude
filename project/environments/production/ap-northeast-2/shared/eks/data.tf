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
    bucket  = "eks-practice-tfstate-mgmt"
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
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/production/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# monitoring(Hub)이 이 spoke의 EKS API에 접근할 때 나가는 출발 IP(locals.tf 참고).
# tag:Name은 monitoring cluster_name과 동일한 값으로, project 네이밍 컨벤션상 결정론적이다
# (monitoring/environments/ap-northeast-2/shared/vpc/locals.tf의 additional_tags.Name).
data "aws_nat_gateway" "monitoring" {
  provider = aws.monitoring
  state    = "available"

  filter {
    name   = "tag:Name"
    values = ["eks-practice-mon"]
  }
}
