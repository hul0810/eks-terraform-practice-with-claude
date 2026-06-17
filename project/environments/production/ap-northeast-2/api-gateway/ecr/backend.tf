terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-MGMT_ACCOUNT_ID"
    key          = "project/production/ap-northeast-2/api-gateway/ecr/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true

    profile = "terraform"

    assume_role = {
      role_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:role/TerraformExecutionRole"
    }
  }
}
