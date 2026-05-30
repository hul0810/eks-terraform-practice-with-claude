# VPC root module 상태에서 vpc_id, private_subnet_ids 가져옴.
# VPC가 먼저 apply되어 있어야 동작한다.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-891396992584"
    key     = "develop/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
    assume_role = {
      role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
    }
  }
}
