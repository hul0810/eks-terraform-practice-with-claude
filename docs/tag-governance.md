# 태그 거버넌스 설계

## 배경 및 한계

AWS Organizations Tag Policy는 태그 **컴플라이언스 가시성** 도구다. 리소스 생성 차단이 기본 목적이 아니다.

| 오해 | 실제 동작 |
|------|-----------|
| Tag Policy의 `tag_value`로 잘못된 값을 막을 수 있다 | `ListRequiredTags` API는 키 목록만 반환. 값 정보는 노출되지 않는다 |
| `tag_policy_compliance = "error"`가 값 위반도 잡는다 | 키 부재만 감지. 값 `"invalid"` 설정해도 통과한다 |
| `enforced_for`로 Terraform을 강제할 수 있다 | `report_required_tag_for`로 대체됨. `enforced_for`는 `ListRequiredTags`와 연동되지 않는다 |

---

## 3계층 거버넌스 구조

```
AWS Organizations Tag Policy (global/tag-policy/)
    ├── 허용값 정의 (tag_value @@assign)
    ├── AWS 수준 컴플라이언스 리포팅 (Tag Editor, AWS Config)
    └── report_required_tag_for → ListRequiredTags API 활성화

tag_policy_compliance = "error" (각 root module providers.tf)
    └── Terraform plan 시 태그 키 부재 차단
        예: environment 태그 자체가 없으면 plan 실패

validate_tags precondition (각 root module main.tf)
    └── Terraform plan 시 태그 값 위반 차단
        예: environment = "staging" → plan 실패
        허용값은 global/tag-policy remote state에서 읽어옴
```

---

## 허용값 단일 소스 원칙

허용값(`environment`, `managed_by`)은 `global/tag-policy/main.tf`의 `@@assign` 배열이 **유일한 정의 지점**이다.

```
global/tag-policy/main.tf        ← 허용값 정의
    ↓ (terraform apply)
global/tag-policy/outputs.tf     ← allowed_environments, allowed_managed_by, allowed_projects 출력
    ↓ (terraform_remote_state)
각 root module data.tf           ← 허용값 읽기
    ↓
각 root module main.tf           ← validate_tags precondition에서 사용
```

허용값을 추가·변경할 때:
1. `global/tag-policy/main.tf`의 `@@assign` 배열만 수정
2. `global/tag-policy/`에서 `terraform apply`
3. 이후 각 root module은 자동으로 새 허용값을 적용받음 (코드 수정 불필요)

---

## 현재 허용값

| 태그 키 | 허용값 |
|---------|--------|
| `environment` | `develop`, `production`, `common` |
| `managed_by` | `terraform` |
| `project` | `eks-practice` |

---

## 신규 Root Module 작성 체크리스트

새 환경 디렉토리(`environments/*/`)를 만들 때 아래 3가지를 반드시 포함한다.

### 1. `providers.tf` — tag_policy_compliance 설정

```hcl
provider "aws" {
  # ...
  # Organizations 정책 report_required_tag_for 리소스 타입에서 태그 키 누락 시 plan 차단.
  # 태그 값 유효성 검사는 main.tf의 validate_tags precondition이 담당.
  tag_policy_compliance = "error"

  default_tags {
    tags = local.common_tags
  }
}
```

### 2. `data.tf` — tag-policy remote state 참조

```hcl
# 태그 허용값을 Organizations 정책에서 읽어온다. 정책 변경 시 이 파일은 수정하지 않아도 된다.
data "terraform_remote_state" "tag_policy" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-891396992584"
    key     = "global/ap-northeast-2/tag-policy/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
    assume_role = {
      role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
    }
  }
}
```

### 3. `main.tf` — validate_tags precondition

```hcl
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
```

---

## 현재 적용 현황

| Root Module | tag_policy_compliance | validate_tags | remote state |
|-------------|----------------------|---------------|--------------|
| `global/tag-policy` | ✅ | — (정책 자신) | — |
| `develop/vpc` | ✅ | ✅ | ✅ |
| `develop/eks` | ✅ | ✅ | ✅ |

---

## 관련 파일

- 정책 정의: `global/tag-policy/main.tf`
- 허용값 출력: `global/tag-policy/outputs.tf`
- 적용 예시: `project/environments/develop/ap-northeast-2/shared/vpc/`
