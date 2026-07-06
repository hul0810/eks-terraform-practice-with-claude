terraform {
  backend "s3" {
    bucket       = "eks-practice-tfstate-workload"
    key          = "project/common/ap-northeast-2/github-workflow-oidc/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true

    profile = "terraform-workload"
  }
}
