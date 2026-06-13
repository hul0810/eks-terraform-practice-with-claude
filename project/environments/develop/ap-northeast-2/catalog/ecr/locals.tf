locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # 리포지토리 이름 패턴: {project}-{service}{name_suffix}
  # 이 root module은 catalog 서비스 전용이다. 다른 서비스의 ECR은
  # project/environments/develop/ap-northeast-2/{service}/ecr/ 에 별도 root module로 관리한다.
  repositories = {
    "${local.project}-catalog${local.name_suffix}" = {
      # dev 환경: 이미지 10개 초과분 자동 삭제로 저장소 비용 통제
      lifecycle_tagged_count = 10
      # 나머지 설정은 모듈 기본값 사용:
      #   image_tag_mutability = "IMMUTABLE" (태그 덮어쓰기 방지)
      #   scan_on_push         = true        (ECR Basic 스캔, 무료)
      #   encryption_type      = "AES256"    (비용 절감)
    }
  }
}
