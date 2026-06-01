terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-891396992584"
    key          = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "terraform"
    use_lockfile = true

    assume_role = {
      role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
    }
  }
}
