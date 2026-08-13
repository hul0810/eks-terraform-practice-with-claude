# Terraform 실행자의 계정 ID 조회 — ACM ARN 동적 구성에 사용
data "aws_caller_identity" "current" {}

# eks/ state에서 클러스터 정보 참조 (cluster_name, cluster_endpoint, oidc_provider_arn).
# eks/ root module이 먼저 apply된 상태를 전제로 한다.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/eks/terraform.tfstate"
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

# SGP Pod SG. 이 root가 아니라 pods-sg가 소유한다 — teardown 대상이 아니어서 ID가 고정되고,
# devops-manifest의 SecurityGroupPolicy가 그 값을 안정적으로 참조할 수 있다.
# 여기서는 노드 SG가 얽히는 규칙(DNS·probe)을 만들기 위해 ID와 probe 포트만 읽는다.
data "terraform_remote_state" "pods_sg" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/pods-sg/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# SSM SecureString 파라미터 기본 암호화 키. External Secrets Operator가 SecureString 파라미터를
# 복호화할 때 이 키에 대한 kms:Decrypt 권한만 허용한다 (계정 내 모든 KMS 키 와일드카드 대신 최소 권한).
data "aws_kms_alias" "ssm_default" {
  name = "alias/aws/ssm"
}

# 운영자 공인 IP CIDR — 로컬 tfvars 파일 대신 SSM Parameter Store(Standard tier)에서 조회
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/develop/eks-addons/operator-ip-cidr --type String --value "x.x.x.x/32" --overwrite
data "aws_ssm_parameter" "operator_ip_cidr" {
  name = "/eks-practice/develop/eks-addons/operator-ip-cidr"
}

# ArgoCD admin 초기 패스워드 bcrypt 해시 — SecureString으로 저장 (with_decryption 기본값 true)
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/develop/eks-addons/argocd-admin-password-bcrypt --type SecureString --value "<bcrypt hash>" --overwrite
data "aws_ssm_parameter" "argocd_admin_password_bcrypt" {
  name = "/eks-practice/develop/eks-addons/argocd-admin-password-bcrypt"
}
