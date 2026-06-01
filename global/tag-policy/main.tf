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
# 콘솔/CLI: 차단하지 않는다 (enforcement_mode 없음 = WARN).
# Terraform: tag_policy_compliance = "error" + report_required_tag_for로 키 누락 시 plan 차단.
#   - report_required_tag_for: Terraform provider의 ListRequiredTags API(2025-11)와 연동되는 필드.
#   - enforced_for는 이 API와 무관한 구형 필드로 tag_policy_compliance에 영향을 주지 않음.
# 태그 값 유효성(@@assign 준수): validate_tags precondition이 담당.
resource "aws_organizations_policy" "required_tags" {
  name        = "eks-practice-required-tags"
  description = "EKS Practice 계정 필수 태그 정책 (Terraform 전용 강제화)"
  type        = "TAG_POLICY"

  depends_on = [terraform_data.require_tag_policy_enabled]

  content = jsonencode({
    tags = {
      environment = {
        tag_key = {
          "@@assign" = "environment"
        }
        # 허용값 문서화: 거버넌스 기준 정의 및 validate_tags remote state output의 단일 소스.
        tag_value = {
          "@@assign" = ["develop", "production", "common"]
        }
        # tag_policy_compliance가 이 리소스 타입에서 키 누락을 plan 단계에서 차단한다.
        report_required_tag_for = {
          "@@assign" = [
            "ec2:vpc",
            "ec2:subnet",
            "ec2:internet-gateway",
            "ec2:route-table",
            "ec2:security-group",
            "ec2:natgateway",
            "eks:cluster",
            "eks:nodegroup"
          ]
        }
      }
      managed_by = {
        tag_key = {
          "@@assign" = "managed_by"
        }
        tag_value = {
          "@@assign" = ["terraform"]
        }
        report_required_tag_for = {
          "@@assign" = [
            "ec2:vpc",
            "ec2:subnet",
            "ec2:internet-gateway",
            "ec2:route-table",
            "ec2:security-group",
            "ec2:natgateway",
            "eks:cluster",
            "eks:nodegroup"
          ]
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
