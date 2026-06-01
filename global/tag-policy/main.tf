data "aws_organizations_organization" "current" {}
data "aws_caller_identity" "current" {}

# TAG_POLICY 활성화 여부를 사전 검증한다.
# 콘솔에서 활성화: Organizations → 정책 → 태그 정책 → 활성화
resource "terraform_data" "require_tag_policy_enabled" {
  lifecycle {
    precondition {
      condition     = contains(data.aws_organizations_organization.current.enabled_policy_types, "TAG_POLICY")
      error_message = "TAG_POLICY가 비활성화 상태입니다. AWS 콘솔 → Organizations → 정책 → 태그 정책 → [활성화] 후 다시 apply 하세요."
    }
  }
}

# --------------------------------------------------
# AWS Organizations 태그 정책
# --------------------------------------------------
# enforcement_mode = WARN: 콘솔/CLI로 생성하는 임시 리소스는 차단하지 않는다.
# Terraform 관리 리소스는 tag_policy_compliance = "error"로 별도 강제화한다.
# → Terraform 코드 품질 보장 + 스타트업 개발 속도 보장을 동시에 달성.
resource "aws_organizations_policy" "required_tags" {
  name        = "eks-practice-required-tags"
  description = "EKS Practice 계정 필수 태그 정책 (Terraform 전용 강제화)"
  type        = "TAG_POLICY"

  depends_on = [terraform_data.require_tag_policy_enabled]

  content = jsonencode({
    tags = {
      # 허용값 명시: 오타(dev, prod 등) 방지 및 거버넌스 문서화 역할
      environment = {
        tag_value = {
          "@@assign" = ["develop", "production", "common"]
        }
      }
      managed_by = {
        tag_value = {
          "@@assign" = ["terraform"]
        }
      }
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# 단일 계정 환경: 계정 ID로 연결해 정확한 범위를 지정한다.
# 멀티 계정 확장 시: Root가 아니라 OU ID로 교체한다.
# Root 연결은 마스터·보안·Sandbox 계정까지 무차별 적용되어 범위가 너무 광범위하다.
resource "aws_organizations_policy_attachment" "required_tags" {
  policy_id = aws_organizations_policy.required_tags.id
  target_id = data.aws_caller_identity.current.account_id

  lifecycle {
    prevent_destroy = true
  }
}
