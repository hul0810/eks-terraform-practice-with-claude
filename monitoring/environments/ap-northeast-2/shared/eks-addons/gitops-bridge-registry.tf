################################################################################
# GitOps Bridge Registry — spoke(dev/prod) self-service 등록
#
# [배경 — 기존 gitops-bridge-spokes.tf의 문제]
# 기존에는 이 root가 dev/prod 클러스터 정보를 손으로 유지하는 map(구 local
# gitops_bridge_spokes)과, addon IAM Role ARN을 "${cluster_name}-lbc-irsa" 같은
# 문자열 패턴으로 추측 재조합하는 local(구 addon_iam_metadata)을 가지고 있었다 — spoke가
# 늘어날 때마다 이 Hub 코드를 고쳐야 했고, spoke 자신이 이미 정확히 아는 IAM ARN을 Hub가
# 네이밍 규칙으로 추측해야 했다(계정 ID·역할 이름이 바뀌면 조용히 깨지는 구조 — 파일 자체
# 주석에도 "cross-account remote_state로 바꾸면 이 local이 필요 없다"고 스스로 적혀 있었다).
#
# [설계 — self-service 레지스트리]
# spoke(project/environments/{develop,production}/.../eks-addons/gitops-bridge-registry.tf)가
# 자신의 클러스터 정보(엔드포인트/CA, spoke Role ARN, addon IAM 메타데이터)를 이 계정의
# SSM Parameter Store(Standard tier, String — 값이 endpoint/ARN 같은 식별자라 진짜 비밀이
# 아니므로 SecureString 불필요)에 직접 쓴다. 이 root는 그 경로를 discovery
# (data.aws_ssm_parameters_by_path)로 읽기만 한다 — spoke가 늘어나도 이 root는 코드 변경이
# 필요 없다. 실제 소비(local 조합, module for_each)는 gitops-bridge-spokes.tf가 담당한다.
#
# [크로스 계정 쓰기 권한 — 최소 권한 Role]
# spoke가 이 계정에 쓰려면 크로스 계정 IAM Role이 필요하다. monitoring 계정 전체에 대한
# admin 권한(SSO 프로필 스왑 — 이 root가 과거 크로스 계정 describe에 쓰던 aws.workload
# alias 방식, 이 레지스트리 도입과 함께 삭제됨)을 그대로 주면 spoke가 이 계정 전체를
# 건드릴 수 있게 되어 최소 권한 원칙에 위배된다.
# 대신 SSM 관련 액션만 허용하고, 그마저도 신뢰 계정마다 별도 Role + 리터럴 고정된 자기
# 계정 prefix로 스코프를 좁힌다(아래 WHY 참고 — 애초에 self-scope 변수로 시도했다가
# 실제로는 작동하지 않는다는 걸 실측으로 확인하고 이 방식으로 바꿨다) — "새 IAM 신뢰
# 관계는 최소 권한 원칙을 엄격히 지킬 것"(CLAUDE.md).
################################################################################

# [신뢰 principal — 계정마다 별도 Role, aws:PrincipalOrgID 조건 아님]
# 이 프로젝트는 이미 AWS Organizations 아래 있다(global/tag-policy가 TAG_POLICY를 관리 —
# data.aws_organizations_organization으로 확인). 하지만 조직 전체 거버넌스(SCP·IAM Identity
# Center 중앙화 등, TODO_LIST.md Phase 7)는 아직 미완료 상태라, "조직 구성원이면 전부 신뢰"
# 조건보다 지금 실제로 이 레지스트리에 쓰기가 필요한 계정만 명시적으로 나열하는 편이 더 좁은
# 신뢰 경계다. local.trusted_spoke_account_ids(locals.tf)에 계정을 추가하는 것만으로 확장
# 가능하다. Phase 7이 끝나 조직 거버넌스가 자리잡으면 Principal을 "*"로 열고 Condition에
# StringEquals { "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id }를
# 추가하는 방식으로 전환할 수 있다.
#
# [WHY — 계정 하나당 Role 하나(Role 공유 + aws:PrincipalAccount 셀프스코프가 아님)]
# 원래는 Role 하나를 여러 계정이 공유해서 assume하고, 정책의 Resource를
# "${aws:PrincipalAccount}"로 self-scope하려 했다. 하지만 실제 develop(657231015203)로
# assume-role 후 ssm:PutParameter를 호출해보니 AccessDeniedException이 났다 — CloudTrail/
# 에러 메시지로 직접 확인한 결과, assumed-role 세션에서 그 Role 자신의 identity-based
# policy를 평가할 때 aws:PrincipalAccount는 "원래 호출자 계정"이 아니라 **Role이 속한
# 계정(이 Hub 자신, 157325288431)**으로 평가된다 — resource policy의 Condition에서
# "누가 이 리소스를 부르는가"를 검사하는 것과 정반대 상황이라 실제로 다르게 동작한다.
# 그래서 self-scope 변수를 포기하고, 신뢰 계정마다 별도 Role(각자 자기 계정 prefix만
# 하드코딩된 정책)을 for_each로 만든다 — Role 개수는 늘지만, 계정 간 경로 충돌을
# "런타임에 변수가 맞게 평가되길 바라는" 방식이 아니라 애초에 물리적으로 분리해 원천 차단한다.
resource "aws_iam_role" "gitops_bridge_registry_writer" {
  for_each = toset(local.trusted_spoke_account_ids)

  name = "${local.cluster_name}-gitops-bridge-registry-writer-${each.value}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TrustedSpokeAccountAssumeRegistryWriter"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${each.value}:root"
        }
        Action = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = local.common_tags
}

# Resource를 이 Role이 대응하는 계정(each.key) 하나로 리터럴 고정한다 — 변수 평가에
# 의존하지 않으므로 다른 계정의 경로는 애초에 이 정책 문서 자체에 등장하지 않는다.
resource "aws_iam_role_policy" "gitops_bridge_registry_writer" {
  for_each = aws_iam_role.gitops_bridge_registry_writer

  name = "gitops-bridge-registry-write"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteOwnAccountSpokeRegistry"
        Effect = "Allow"
        # GetParameter/ListTagsForResource: 쓰기 권한이 아니라, aws_ssm_parameter 리소스가
        # 생성/변경 직후 자기 값·태그를 다시 읽어 상태를 채우는 표준 Terraform provider Read
        # 동작에 필요하다(실제로 하나씩 빠뜨릴 때마다 AccessDenied로 확인됨).
        # DeleteParameter/RemoveTagsFromResource: teardown(destroy)/값 변경 시 필요 — 지금
        # 당장은 안 쓰지만 이 Role의 생명주기 전체(생성→읽기→갱신→삭제)를 지금 다 갖춰두지
        # 않으면 나중에 destroy 시점에 또 같은 시행착오를 반복하게 된다.
        # 전부 같은 Resource 패턴(이 계정 prefix만)이라 다른 계정 경로는 여전히 손댈 수 없다.
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:DeleteParameter",
          "ssm:AddTagsToResource",
          "ssm:RemoveTagsFromResource",
          "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/gitops-bridge/spokes/${each.key}/*"
      },
      {
        # ssm:DescribeParameters는 검색/목록 API라 GetParameter/PutParameter와 달리 특정
        # 파라미터 ARN으로 Resource를 좁힐 수 없다(AWS 제약 — 실제로 Resource를 파라미터
        # ARN으로 주면 AccessDenied가 난다, 실측 확인). aws_ssm_parameter 리소스가 생성 직후
        # 자기 값을 재조회할 때(태그·tier 등 메타데이터) 이 API도 함께 호출하므로 필요하다.
        # Action 자체는 여전히 이 계정 Role 전용(다른 계정 Role에는 이 statement가 아예 없음)
        # 이라 "전체 파라미터 조회 가능"이 아니라 "이 Role을 assume한 세션만 조회 가능"으로
        # 여전히 좁혀져 있다 — Resource만 AWS API 제약으로 어쩔 수 없이 넓힌 것이다.
        Sid      = "DescribeParametersRequiresWildcardResource"
        Effect   = "Allow"
        Action   = ["ssm:DescribeParameters"]
        Resource = "*"
      }
    ]
  })
}

# spoke가 발행한 등록 정보 discovery. recursive=true로 계정 세그먼트까지 전부 순회한다.
# with_decryption은 의미가 없다(String만 존재, SecureString 없음) — 그래도 명시해 "이 경로에는
# 암호화된 값이 없다"는 설계 의도를 코드로 남긴다.
data "aws_ssm_parameters_by_path" "gitops_bridge_registry" {
  path            = "/eks-practice/gitops-bridge/spokes/"
  recursive       = true
  with_decryption = false
}
