terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-workload"
    key          = "project/develop/ap-northeast-2/shared/rds/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true

    profile = "terraform-workload"
  }
}
