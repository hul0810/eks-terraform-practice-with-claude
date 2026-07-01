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

# 운영자 공인 IP CIDR — 로컬 tfvars 파일 대신 SSM Parameter Store(Standard tier)에서 조회
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/production/eks-addons/operator-ip-cidr --type String --value "x.x.x.x/32" --overwrite
data "aws_ssm_parameter" "operator_ip_cidr" {
  name = "/eks-practice/production/eks-addons/operator-ip-cidr"
}

# ArgoCD admin 초기 패스워드 bcrypt 해시 — SecureString으로 저장 (with_decryption 기본값 true)
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/production/eks-addons/argocd-admin-password-bcrypt --type SecureString --value "<bcrypt hash>" --overwrite
data "aws_ssm_parameter" "argocd_admin_password_bcrypt" {
  name = "/eks-practice/production/eks-addons/argocd-admin-password-bcrypt"
}
