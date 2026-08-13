# 태그 허용값 단일 소스. 상세: docs/tag-governance.md
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-mgmt"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
  }
}

# VPC ID와 데이터베이스 전용 서브넷 참조.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# SGP Pod 전용 SG ID 참조. pods-sg는 클러스터 lifecycle과 분리된 영속 root라(teardown 대상 아님)
# 이 root가 언제 apply되든 SG가 이미 존재한다 — eks-addons를 거치지 않는다.
data "terraform_remote_state" "pods_sg" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-workload"
    key     = "project/develop/ap-northeast-2/shared/pods-sg/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform-workload"
  }
}

# 마스터 사용자 패스워드 — SecureString으로 저장하고 Terraform은 읽기만 한다.
# manage_master_user_password(Secrets Manager 위임) 대신 SSM을 쓰는 이유: Secrets Manager는
# 시크릿당 $0.40/월이 발생하고, 이 프로젝트는 이미 ArgoCD 패스워드 등을 SSM Standard(무료)로
# 관리하는 패턴이 있다.
#
# 값 등록:
#   aws ssm put-parameter --name /eks-practice/develop/rds/master-password \
#     --type SecureString --value "<password>" --overwrite --profile terraform-workload
data "aws_ssm_parameter" "master_password" {
  name = "/eks-practice/develop/rds/master-password"
}
