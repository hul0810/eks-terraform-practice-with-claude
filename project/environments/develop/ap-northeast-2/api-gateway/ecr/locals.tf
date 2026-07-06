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
  # 이 root module은 api-gateway 서비스 전용이다. 다른 서비스의 ECR은
  # project/environments/develop/ap-northeast-2/{service}/ecr/ 에 별도 root module로 관리한다.
  repositories = {
    "${local.project}-api-gateway${local.name_suffix}" = {
      # dev 환경: 이미지 10개 초과분 자동 삭제로 저장소 비용 통제
      lifecycle_tagged_count = 10
      # workload 계정 이관을 위해 이미지 포함 강제 삭제 허용
      force_delete = true
      # monitoring 클러스터의 ArgoCD Image Updater(IRSA)가 크로스 계정으로 이미지 태그를
      # 조회할 수 있도록 read 권한 부여 — modules/ecr가 repository policy를 자동 생성한다.
      # try()+compact()로 소프트 참조: monitoring eks-addons는 파일럿 애드온이라 /env-teardown
      # monitoring으로 자주 destroy된다. 하드 참조([<arn>] 그대로)면 그 시점에 output 자체가
      # state에서 사라져 이 root의 plan/apply가 전부 실패한다. Role이 없으면 빈 리스트로 폴백해
      # repository policy statement 자체가 생성되지 않도록 한다(권한 없음 = 안전한 기본값).
      read_access_arns = compact([try(data.terraform_remote_state.monitoring_eks_addons.outputs.argocd_image_updater_role_arn, "")])
      # ArgoCD Image Updater digest 전략 실습을 위해 동일 태그(latest) 반복 push가 필요하므로
      # dev 환경은 MUTABLE로 구성한다. prod는 배포 불변성 보장을 위해 모듈 기본값 IMMUTABLE을 유지한다.
      image_tag_mutability = "MUTABLE"
      # 나머지 설정은 모듈 기본값 사용:
      #   scan_on_push    = true      (ECR Basic 스캔, 무료)
      #   encryption_type = "AES256"  (비용 절감)
    }
  }
}
