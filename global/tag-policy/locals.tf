locals {
  # providers.tf default_tags의 단일 정의 지점.
  # global 리소스는 환경 구분 없이 "common"으로 태깅.
  common_tags = {
    environment = "common"
    managed_by  = "terraform"
    project     = "eks-practice"
  }

  # 태그 정책 적용 대상 계정 목록.
  # 신규 계정 추가 시 여기에만 추가하면 된다.
  # 멀티 계정 규모 확장 시: 계정 ID 대신 OU ID로 교체 검토.
  _policy_target_account_ids = toset([
    "MGMT_ACCOUNT_ID", # 관리 계정
    "WORKLOAD_ACCOUNT_ID", # workload 계정
    "MONITORING_ACCOUNT_ID", # monitoring 계정
  ])
}
