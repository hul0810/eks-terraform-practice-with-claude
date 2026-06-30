terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-monitoring"
    key          = "monitoring/ap-northeast-2/shared/vpc/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
    profile      = "terraform-monitoring"
  }
}
