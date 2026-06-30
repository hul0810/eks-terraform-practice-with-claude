terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-workload"
    key          = "project/production/ap-northeast-2/catalog/ecr/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true

    profile = "terraform-workload"
  }
}
