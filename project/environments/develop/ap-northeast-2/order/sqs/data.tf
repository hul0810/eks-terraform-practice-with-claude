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

# Pod Identity 신뢰 정책의 aws:SourceAccount 조건에 사용
data "aws_caller_identity" "current" {}

# eks/ state에서 클러스터 이름 참조. eks/ root module이 먼저 apply된 상태를 전제로 한다.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/eks/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# Pod Identity 신뢰 정책의 aws:SourceArn 조건에 쓸 클러스터 ARN 조회.
# eks/ outputs에 cluster_arn이 없어 data source로 가져온다.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}
