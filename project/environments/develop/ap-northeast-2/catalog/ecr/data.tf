# 태그 허용값을 Organizations 정책에서 읽어온다. 정책 변경 시 이 파일은 수정하지 않아도 된다.
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-mgmt"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

# ArgoCD Image Updater IRSA Role ARN — ECR repository policy(read_access_arns)에서 참조한다.
# monitoring/environments/ap-northeast-2/shared/eks-addons/argocd-image-updater.tf 참조.
data "terraform_remote_state" "monitoring_eks_addons" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-monitoring"
    key     = "monitoring/ap-northeast-2/shared/eks-addons/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-monitoring"
  }
}
