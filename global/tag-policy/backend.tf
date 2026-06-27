terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-MGMT_ACCOUNT_ID"
    key          = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "terraform"
    use_lockfile = true
  }
}
