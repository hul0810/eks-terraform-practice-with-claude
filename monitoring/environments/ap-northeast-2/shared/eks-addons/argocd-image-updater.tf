################################################################################
# ArgoCD Image Updater — monitoring 클러스터 전용 파일럿 설치
#
# [왜 modules/eks-addons(공유 모듈)가 아니라 이 root에서 직접 관리하는가]
# eks-blueprints-addons(aws-ia/eks-blueprints-addons ~> 1.23.0)는 ArgoCD 자체(enable_argocd/
# argocd 변수)만 지원하고 Image Updater 서브모듈이 없다. develop/production도 각자 ArgoCD를
# 운영하지만 Image Updater는 monitoring에서만 파일럿 운영하기로 결정했으므로, 3개 환경이 공유하는
# modules/eks-addons에 넣지 않고 이 root의 helm_release로 직접 관리한다.
#
# [ECR 인증 방식 — ext: 스크립트 + IRSA, assume-role 아님]
# argocd-image-updater는 ECR을 네이티브 지원하지 않는다(공식 문서 registries.md의 지원 레지스트리
# 목록에 ECR 미포함). 대신 외부 스크립트가 로그인 토큰을 stdout으로 출력하는 `ext:<script>` 방식을
# 공식 문서가 ECR의 대표 사용례로 명시한다(docs/basics/authentication.md:
# "A prominent example would be ECR on aws").
#
# catalog/order/api-gateway ECR 저장소는 workload 계정(657231015203)에 있고 monitoring 클러스터
# 계정(157325288431)과 다르다. ECR의 GetAuthorizationToken은 호출자 자신의 계정에서 발급되는
# 범용 토큰이라 assume-role 없이 동일 토큰으로 다른 계정 레지스트리에 접근할 수 있다는 점까지는
# 맞지만, 실제 이미지/태그 조회(BatchGetImage 등)가 성립하려면 IAM 평가 로직이 same-account와
# 다르다: same-account는 identity 기반 정책 또는 resource 기반 정책 중 하나만 허용해도 되지만,
# cross-account는 호출자 쪽 identity 기반 정책과 대상 리소스의 resource 기반 정책 둘 다
# 명시적으로 허용해야 성립하는 AND 로직이다. 초기에는 이 사실을 놓치고 GetAuthorizationToken만
# identity 측에 부여한 채 workload 계정 repository policy(read_access_arns)만으로 충분하다고
# 가정했다가 실제 태그 조회에서 403이 발생했다(로그인은 되지만 조회가 막힘 — AND 조건 중 identity
# 측이 비어 있었기 때문).
# 따라서 이 IRSA Role에는 GetAuthorizationToken(계정 단위, 아래 별도 정책) 외에도 실제 조회에
# 필요한 identity 측 read 액션(BatchGetImage/DescribeImages/ListImages/DescribeRepositories/
# GetDownloadUrlForLayer/BatchCheckLayerAvailability)을 workload 계정 저장소 전체(현재 6개)에
# prefix 와일드카드로 스코프를 좁혀 부여한다(아래 argocd_image_updater_ecr_read). resource 측 허용은 여전히
# project/environments/{develop,production}/ap-northeast-2/*/ecr/locals.tf의 read_access_arns에
# 이 Role ARN을 추가하는 방식으로 부여한다(modules/ecr가 repository policy를 자동 생성) —
# 두 방향 모두 있어야 cross-account 조회가 성립한다.
#
# [docker-credential-ecr-login을 initContainer로 주입하는 이유 — aws-cli가 아닌 이유]
# ext: 스크립트는 ECR 로그인 토큰을 발급하는 바이너리가 필요한데, 차트 기본 이미지
# (quay.io/argoprojlabs/argocd-image-updater)는 Alpine(musl libc) 기반이라 aws-cli(glibc 바이너리)를
# 그대로 복사해 넣으면 "exec: no such file or directory"로 실행 자체가 안 된다(동적 링커 경로가
# 다른 libc를 가리켜 파일이 있어도 실행 불가 — 실제로 이 프로젝트에서 aws-cli로 먼저 시도했다가
# 이 문제로 교체했다). 대신 AWS 공식 amazon-ecr-credential-helper(docker-credential-ecr-login)를
# 쓴다 — Alpine aports 공식 패키지로 배포되어 musl 바이너리를 그대로 얻을 수 있고, Go 정적 바이너리라
# 별도 공유 라이브러리 의존성도 없다. initContainer 이미지를 메인 컨테이너와 같은 Alpine 버전으로
# 맞춰 apk로 설치한 바이너리를 emptyDir에 복사한다.
# IRSA 자격증명은 pod 수명 동안 projected token으로 자동 갱신되므로, 스크립트는 매 호출마다
# 새로 서명된 요청을 보낼 뿐 initContainer의 1회성 실행과는 무관하게 계속 동작한다.
#
# [모니터링 대상 레지스트리가 1개뿐인 이유]
# dev/prod 이미지 저장소(6개)가 모두 동일 계정(workload)의 동일 리전 ECR에 있으므로
# 레지스트리 호스트(<account>.dkr.ecr.<region>.amazonaws.com)는 1개다. registries.conf는
# 저장소가 아니라 호스트 단위로 인증을 구성하므로 항목도 1개면 충분하다.
#
# [개별 애플리케이션의 ImageUpdater CR은 이 root의 관리 범위 밖]
# 어떤 이미지를 추적할지(images, applicationRefs)는 실제 ArgoCD Application이 배포된 이후에
# 결정되는 서비스별 설정이다. docs/addon-strategy.md "GitOps 관리 경계" 판단 기준(ArgoCD 자신의
# 부트스트랩에 필요한 리소스인가?)에 따르면 이는 아니오에 해당하므로, ImageUpdater CR은 이 root가
# 아니라 eks-practice-devops-manifest 저장소(GitOps)에서 서비스 매니페스트와 함께 관리한다.
################################################################################

resource "aws_iam_role" "argocd_image_updater" {
  name = "${local.cluster_name}-argocd-image-updater-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ArgocdImageUpdaterIrsa"
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:argocd:argocd-image-updater"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# GetAuthorizationToken은 리소스 수준 권한을 지원하지 않는 계정 단위 액션이라 Resource = "*"가
# 유일한 형태다(AWS 공식 문서: ECR 액션별 리소스 수준 권한 표에서 GetAuthorizationToken은 "전체").
# 실제 저장소 read 권한은 workload 계정 ECR repository policy(read_access_arns)에서 부여한다.
resource "aws_iam_role_policy" "argocd_image_updater_ecr_auth" {
  name = "ecr-get-authorization-token"
  role = aws_iam_role.argocd_image_updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrGetAuthorizationToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      }
    ]
  })
}

# cross-account ECR 조회 성립에 필요한 identity 측 read 액션 (위 헤더 주석의 AND 로직 참고).
# AmazonEC2ContainerRegistryReadOnly 관리형 정책으로 임시 검증했으나, 그 정책은 Resource="*"로
# GetLifecyclePolicy/GetRepositoryPolicy/DescribeImageScanFindings/ListTagsForResource 등 이미지
# 태그 감지에 쓰이지 않는 액션까지 광범위하게 부여한다. 이 파일의 기존 최소 권한 패턴(위
# argocd_image_updater_ecr_auth)과 일관되게, 실제 필요한 조회 액션만 부여한다.
# Resource는 개별 리포지토리 이름을 나열하지 않고 "eks-practice-*" 프리픽스 와일드카드로 스코프를
# 좁힌다 — 계정(workload) + 프로젝트 네이밍 프리픽스로 이미 충분히 제한되면서도, 새 서비스 ECR이
# project/environments/{develop,production}/ap-northeast-2/*/ecr/에 추가될 때마다 이 리스트를
# 수동 갱신하지 않아도 된다(누락 시 태그 조회 단계에서만 조용히 403이 나는 위험 제거).
resource "aws_iam_role_policy" "argocd_image_updater_ecr_read" {
  name = "ecr-image-tag-read"
  role = aws_iam_role.argocd_image_updater.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcrImageTagRead"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:ap-northeast-2:${local.workload_account_id}:repository/eks-practice-*"
      }
    ]
  })
}

# Helm release(ecr-login.sh authScripts, initContainer, registries 설정 등)는 GitOps
# Bridge(Phase 6-4)로 이관 완료 — eks-practice-devops-manifest 저장소의 ArgoCD Application이
# 관리한다. 이 값들을 바꾸려면 이 저장소가 아니라 그쪽 저장소의 values-override.yaml을
# 수정한다. IAM Role/Policy(위)는 계속 Terraform이 관리한다.
