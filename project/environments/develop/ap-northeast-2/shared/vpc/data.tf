data "aws_availability_zones" "available" {
  state = "available"
}

# 태그 허용값을 Organizations 정책에서 읽어온다. 정책 변경 시 이 파일은 수정하지 않아도 된다.
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-891396992584"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
    assume_role = {
      role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
    }
  }
}
