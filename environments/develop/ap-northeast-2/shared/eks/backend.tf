terraform {
  backend "s3" {
    bucket         = "eks-practice-tfstate-891396992584"
    key            = "develop/ap-northeast-2/shared/eks/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "eks-practice-tfstate-lock"
    encrypt        = true
    profile        = "terraform"
    assume_role    = { role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole" }
  }
}
