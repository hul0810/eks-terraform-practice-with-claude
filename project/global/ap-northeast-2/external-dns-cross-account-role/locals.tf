locals {
  project = "eks-practice"

  # 글로벌 리소스 — 특정 환경에 속하지 않으므로 "common" 사용
  common_tags = {
    environment = "common"
    managed_by  = "terraform"
    project     = local.project
  }

  # monitoring eks-addons state에서 ExternalDNS IRSA ARN 참조
  external_dns_irsa_arn = data.terraform_remote_state.monitoring_eks_addons.outputs.external_dns_role_arn

  # pyhtest.com Route53 Hosted Zone ID — workload 계정 소유, Terraform 외부 관리 리소스 (하드코딩)
  route53_zone_id = "Z0947901KS8HHREY0RFC"
}
