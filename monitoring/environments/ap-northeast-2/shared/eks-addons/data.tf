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

# workload 계정 external-dns-cross-account-role state에서 크로스 계정 Role ARN 참조
data "terraform_remote_state" "external_dns_cross_account_role" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/global/ap-northeast-2/external-dns-cross-account-role/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# External Secrets Operator IAM 스코프 계산용 — monitoring 계정 ID
data "aws_caller_identity" "current" {}

# SSM SecureString 파라미터 기본 암호화 키. External Secrets Operator가 GitHub App
# 인증 정보(SecureString)를 복호화할 때 이 키에 대한 kms:Decrypt 권한만 허용한다
# (계정 내 모든 KMS 키 와일드카드 대신 최소 권한으로 스코프).
data "aws_kms_alias" "ssm_default" {
  name = "alias/aws/ssm"
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
