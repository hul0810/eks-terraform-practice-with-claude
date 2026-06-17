# eks/ state에서 클러스터 정보 참조 (cluster_name, cluster_endpoint, oidc_provider_arn).
# eks/ root module이 먼저 apply된 상태를 전제로 한다.
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-MGMT_ACCOUNT_ID"
    key     = "project/production/ap-northeast-2/shared/eks/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
    assume_role = {
      role_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:role/TerraformExecutionRole"
    }
  }
}

# helm/kubernetes provider 초기화용.
# data "terraform_remote_state".eks.outputs.cluster_endpoint와 동일한 값이지만
# provider 설정 블록에서는 locals와 remote_state를 참조할 수 없어 data source를 별도로 사용한다.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# ArgoCD 외부 접근(argocd.pyhtest.com)용 — 기존 pyhtest.com Hosted Zone(Terraform 미관리) 참조
data "aws_route53_zone" "pyhtest" {
  name         = "pyhtest.com"
  private_zone = false
}

# argocd.pyhtest.com 커버하는 기존 인증서 재사용 (신규 발급 불필요)
# ACM의 domain 필터는 인증서의 기본 도메인(DomainName="pyhtest.com")을 기준으로 매칭한다.
# SAN에 포함된 "*.pyhtest.com"으로는 조회되지 않으므로 "pyhtest.com"으로 조회한다.
# key_types 미지정 시 RSA/ECDSA 인증서가 동시에 존재하면 most_recent의 선택 결과가
# 예측 불가능해진다. ACM 기본 발급 키 타입(RSA_2048)으로 명시해 모호성을 제거한다.
data "aws_acm_certificate" "pyhtest_wildcard" {
  domain      = "pyhtest.com"
  statuses    = ["ISSUED"]
  key_types   = ["RSA_2048"]
  most_recent = true
}
