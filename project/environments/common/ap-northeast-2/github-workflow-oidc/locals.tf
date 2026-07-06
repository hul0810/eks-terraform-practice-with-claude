locals {
  project = "eks-practice"

  common_tags = {
    environment = "common"
    managed_by  = "terraform"
    project     = local.project
  }

  github_org  = "hul0810"
  github_repo = "eks-practice-application-with-claude"

  # 디렉토리/Role 짧은 이름(key)과 실제 ECR 리포지토리 이름이 다르므로 주의.
  # key는 Role 이름(eks-practice-{key}-github)에 쓰이고, repository_names는 해당 서비스의
  # dev+prod ECR 리포지토리 이름이다.
  services = {
    gateway = ["eks-practice-api-gateway-dev", "eks-practice-api-gateway"]
    catalog = ["eks-practice-catalog-dev", "eks-practice-catalog"]
    order   = ["eks-practice-order-dev", "eks-practice-order"]
  }
}
