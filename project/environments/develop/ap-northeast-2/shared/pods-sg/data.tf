# 태그 허용값 단일 소스. 상세: docs/tag-governance.md
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-mgmt"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

# 이 root가 의존하는 것은 VPC 하나뿐이다. 클러스터·애드온을 참조하지 않기 때문에
# teardown으로 클러스터가 사라져도 이 root는 그대로 유지된다(README 참조).
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# egress 대상 CIDR. strict 모드에서 Pod의 아웃바운드는 이 SG가 온전히 결정하므로
# VPC 내부 목적지를 CIDR로 명시해야 한다.
data "aws_vpc" "this" {
  id = local.vpc_id
}
