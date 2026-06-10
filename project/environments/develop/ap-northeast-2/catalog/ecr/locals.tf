locals {
  environment = "develop"
  project     = "eks-practice"

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # 리포지토리 이름 패턴: {project}-{service}-{environment}
  # 이 root module은 catalog 서비스 전용이다. 다른 서비스의 ECR은
  # project/environments/develop/ap-northeast-2/{service}/ecr/ 에 별도 root module로 관리한다.
  repositories = {
    "${local.project}-catalog-${local.environment}" = {
      # dev 환경: 이미지 10개 초과분 자동 삭제로 저장소 비용 통제
      lifecycle_tagged_count = 10
      # 나머지 설정은 모듈 기본값 사용:
      #   image_tag_mutability = "IMMUTABLE" (태그 덮어쓰기 방지)
      #   scan_on_push         = true        (ECR Basic 스캔, 무료)
      #   encryption_type      = "AES256"    (비용 절감)
    }
  }
}
