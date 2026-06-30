# Terraform 실행자의 계정 ID 조회 — ACM ARN 동적 구성에 사용
data "aws_caller_identity" "current" {}

# eks/ state에서 클러스터 정보 참조 (cluster_name, cluster_endpoint, oidc_provider_arn).
# eks/ root module이 먼저 apply된 상태를 전제로 한다.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/production/ap-northeast-2/shared/eks/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# helm/kubernetes provider 초기화용.
# data "terraform_remote_state".eks.outputs.cluster_endpoint와 동일한 값이지만
# provider 설정 블록에서는 locals와 remote_state를 참조할 수 없어 data source를 별도로 사용한다.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}
