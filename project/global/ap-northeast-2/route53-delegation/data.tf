# monitoring 계정 eks-addons state에서 ExternalDNS IRSA Role ARN을 참조한다.
#
# Apply 순서 (data source 의존성이 순서를 강제한다):
#   1. monitoring/eks-addons apply → ExternalDNS IRSA Role 생성 + state에 external_dns_role_arn output 기록
#   2. 이 모듈(route53-delegation) apply → Trust Policy에 IRSA ARN 주입
#   3. ACM 인증서 발급 (AWS CLI) → monitoring/eks-addons/locals.tf의 acm_certificate_arn UUID 교체
#   4. monitoring/eks-addons 재apply → delegation role ARN + ACM cert ARN 반영
data "terraform_remote_state" "monitoring_eks_addons" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-monitoring"
    key     = "monitoring/ap-northeast-2/shared/eks-addons/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-monitoring"
  }
}
