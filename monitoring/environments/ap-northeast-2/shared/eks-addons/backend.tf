terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-MONITORING_ACCOUNT_ID"
    key          = "monitoring/ap-northeast-2/shared/eks-addons/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
    profile      = "terraform-monitoring"
  }
}
