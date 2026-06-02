locals {
  # providers.tf default_tags의 단일 정의 지점.
  # global 리소스는 환경 구분 없이 "common"으로 태깅.
  common_tags = {
    environment = "common"
    managed_by  = "terraform"
    project     = "eks-practice"
  }
}
