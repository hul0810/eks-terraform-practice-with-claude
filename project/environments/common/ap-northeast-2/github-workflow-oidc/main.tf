# 태그 값 유효성 검사: Organizations 정책의 허용값을 remote state에서 읽어 검증한다.
# 허용값 변경은 global/tag-policy/main.tf만 수정하면 된다.
resource "terraform_data" "validate_tags" {
  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_environments, local.common_tags.environment)
      error_message = "environment 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_environments)}. 현재 값: '${local.common_tags.environment}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_managed_by, local.common_tags.managed_by)
      error_message = "managed_by 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_managed_by)}. 현재 값: '${local.common_tags.managed_by}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_projects, local.common_tags.project)
      error_message = "project 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_projects)}. 현재 값: '${local.common_tags.project}'"
    }
  }
}

################################################################################
# GitHub Actions OIDC → ECR Push
#
# eks-practice-application-with-claude 레포의 release 파이프라인이 장기 자격증명 없이
# OIDC 연동만으로 workload 계정 ECR에 이미지를 push할 수 있도록 한다.
#
# 서비스별로 분리하지 않고 하나의 root module로 통합 관리한다: OIDC Provider는 계정당
# URL 1개만 존재 가능한 singleton이고, 서비스별 Role 3개도 서로 강하게 연관된 하나의
# 관심사(GitHub Actions 인증)이므로 별도 root module 3개로 쪼개는 것보다 for_each로
# 한 곳에서 관리하는 편이 상태 파일 개수 대비 관리 편의성이 높다고 판단했다.
################################################################################

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub Actions OIDC는 AWS가 자체 신뢰 루트 CA로 검증하는 IdP라 thumbprint_list 불필요
  # (aws_iam_openid_connect_provider 리소스 문서: "AWS relies on its own library of
  # trusted root CAs" — GitHub 측 인증서 로테이션 시에도 재설정 불필요)

  lifecycle {
    # 삭제되면 gateway/catalog/order 3개 Role의 AssumeRoleWithWebIdentity가 동시에 끊긴다 —
    # Role 개별 보호보다 폭발 반경이 더 큰 리소스이므로 동일한 실수 방지 가드를 건다.
    prevent_destroy = true
  }
}

resource "aws_iam_role" "github_actions" {
  for_each = local.services

  name        = "${local.project}-${each.key}-github"
  description = "GitHub Actions OIDC role for ${each.key} service release pipeline (dev+prod ECR push)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRepoWorkflows"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # 레포 단위로만 제한한다. 브랜치/이벤트/environment 등 세부 조건은 걸지 않아
          # 워크플로우 쪽 구성(트리거 방식, environment 선언 여부 등)이 바뀌어도 이 root
          # module을 다시 손볼 필요가 없다.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${local.github_org}/${local.github_repo}:*"
          }
        }
      }
    ]
  })

  lifecycle {
    # 삭제되면 GitHub Actions release 파이프라인 인증이 즉시 끊긴다 — 같은 tier의
    # external-dns-cross-account-role과 동일한 이유로 실수 방지 가드를 건다.
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  for_each = local.services

  # Role 이름(eks-practice-{key}-github)과 동일한 규칙으로 맞춰 콘솔에서 소속을 바로 식별할 수 있게 한다.
  name = "${local.project}-${each.key}-github"
  role = aws_iam_role.github_actions[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # 계정 단위 액션이라 리소스 레벨 제한 불가
      },
      {
        Sid    = "PushToOwnRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        # dev+prod 리포지토리 ARN 양쪽 모두 허용 — Role을 환경별로 나누지 않는 설계이므로
        # 서비스 자신의 리포지토리(dev/prod)로만 범위를 최소화한다.
        Resource = [
          for name in each.value : "arn:aws:ecr:ap-northeast-2:${data.aws_caller_identity.current.account_id}:repository/${name}"
        ]
      }
    ]
  })
}
