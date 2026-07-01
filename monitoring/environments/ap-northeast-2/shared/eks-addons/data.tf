data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-monitoring"
    key     = "monitoring/ap-northeast-2/shared/eks/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-monitoring"
  }
}

data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-mgmt"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

# *.pyhtest.com ACM 인증서 — monitoring 계정에 DNS 검증 방식으로 발급, domain 기준 동적 조회
data "aws_acm_certificate" "pyhtest_wildcard" {
  domain      = "*.pyhtest.com"
  statuses    = ["ISSUED"]
  key_types   = ["RSA_2048"]
  most_recent = true
}

# workload 계정 route53-delegation state에서 크로스 계정 위임 Role ARN 참조
data "terraform_remote_state" "route53_delegation" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/global/ap-northeast-2/route53-delegation/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# 운영자 공인 IP CIDR — 로컬 tfvars 파일 대신 SSM Parameter Store(Standard tier)에서 조회
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/monitoring/eks-addons/operator-ip-cidr --type String --value "x.x.x.x/32" --overwrite
data "aws_ssm_parameter" "operator_ip_cidr" {
  name = "/eks-practice/monitoring/eks-addons/operator-ip-cidr"
}

# ArgoCD admin 초기 패스워드 bcrypt 해시 — SecureString으로 저장 (with_decryption 기본값 true)
# 값 등록/갱신: aws ssm put-parameter --name /eks-practice/monitoring/eks-addons/argocd-admin-password-bcrypt --type SecureString --value "<bcrypt hash>" --overwrite
data "aws_ssm_parameter" "argocd_admin_password_bcrypt" {
  name = "/eks-practice/monitoring/eks-addons/argocd-admin-password-bcrypt"
}
