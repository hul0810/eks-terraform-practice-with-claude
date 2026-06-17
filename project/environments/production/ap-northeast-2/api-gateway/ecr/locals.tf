locals {
  environment = "production"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. production은 environment_short를 빈 문자열로 두어 구분자까지 완전히 제거한다.
  environment_short = ""
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # 리포지토리 이름 패턴: {project}-{service}{name_suffix}
  # production: name_suffix="" → "eks-practice-api-gateway"
  # 이 root module은 api-gateway 서비스 전용이다. 다른 서비스의 ECR은
  # project/environments/production/ap-northeast-2/{service}/ecr/ 에 별도 root module로 관리한다.
  repositories = {
    "${local.project}-api-gateway${local.name_suffix}" = {
      # production: 롤백 시나리오를 고려해 30개 보존 (dev는 10개, modules/ecr/CLAUDE.md 권장)
      lifecycle_tagged_count = 30
      # 나머지 설정은 모듈 기본값 사용:
      #   image_tag_mutability = "IMMUTABLE" (태그 덮어쓰기 방지)
      #   scan_on_push         = true        (ECR Basic 스캔, 무료)
      #   encryption_type      = "AES256"    (비용 절감)
    }
  }
}
