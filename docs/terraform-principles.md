# Terraform 작성 원칙

## 엔지니어링 철학

### 초기 구조 확립 원칙
설정 비용이 낮고 장기 효과가 높다면, 현재 규모나 복잡도와 관계없이 올바른 구조를 처음부터 갖춘다.
구조 없이 시작하면 기능이 쌓일수록 대규모 리팩토링, 호환성 검증, 이중 구조 운영 부담이 생긴다.
"지금은 단순하게"가 "나중에 복잡하게"를 만드는지 항상 먼저 검토한다.

### 확장 가능한 구조를 기본값으로
단기 단순함보다 장기 확장성을 우선한다.
모듈 버전 관리, 상태 격리, 명시적 인터페이스는 선택이 아닌 기본값이다.
환경이 늘어나거나 공식 모듈이 업그레이드되어도 기존 리소스에 영향 없이 확장할 수 있는 구조를 목표로 한다.

### 명시성 우선
암묵적 동작보다 명시적 선언을 선호한다.
버전, 의존성, 설정값은 코드에서 명확히 읽힐 수 있어야 한다.
미래의 작업자(혹은 미래의 자신)가 코드만 보고도 의도를 파악할 수 있어야 한다.

---

## MCP 사용 순서

### Terraform 코드 작성 시
- `get_latest_provider_version` → `get_provider_capabilities` → `get_provider_details` 순서로 조회한다.
- 모듈 사용 시 `get_latest_module_version`으로 최신 버전을 확인한다.
- **모든 AWS provider에 `assume_role`을 반드시 포함한다.**
  - profile: `terraform`
  - role_arn: `arn:aws:iam::MGMT_ACCOUNT_ID:role/TerraformExecutionRole`

### AWS 인프라 구축 시
- 신규 AWS 서비스 또는 익숙하지 않은 서비스 사용 시 `aws___read_documentation`으로 공식 문서를 참조한다.

---

## 프로젝트 구조 원칙

- 환경은 `environments/develop`, `environments/production`으로 분리한다.
- 공유 인프라는 `global/`에 위치한다.
- 재사용 가능한 로직은 `modules/`에 모듈로 작성한다.
- 환경별 설정값은 `locals.tf`에 집중 관리한다. `terraform.tfvars`는 사용하지 않는다.
- 태그는 2개만 관리한다: `environment`, `managed_by`
  - `environment`: `develop` / `production` / `common`
  - `managed_by`: `terraform`
  - 키와 값 모두 소문자

---

## 코드 품질

- **동적 메타데이터 활용**: 리전, AZ, 계정 ID 등 AWS가 제공하는 메타데이터는 data source로 조회하며 하드코딩하지 않는다.
  - 가용 영역: `data "aws_availability_zones" { state = "available" }` → `.names`
  - 현재 리전: `data "aws_region" "current" {}` → `.name`
  - 계정 ID: `data "aws_caller_identity" "current" {}` → `.account_id`
  - 특정 AZ 예외(인스턴스 타입 미지원 등)는 data source 결과를 그대로 쓰되 해당 리소스에서 개별 필터링한다.
- **인라인 블록 금지**: 별도 리소스로 분리할 수 있다면 반드시 분리한다.
  - Security Group `ingress` / `egress` → `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`
  - S3 `versioning`, `server_side_encryption_configuration` 등 → 별도 리소스
- **`depends_on` 최소화**: 암묵적 의존성(리소스 참조)을 최대한 활용한다.
- **`moved` 블록 활용**: 리소스 이름 변경이나 모듈 이동 시 state 이전에 사용한다.
- **주석**: WHY가 명확하지 않을 때만 한국어로 작성한다. WHAT 설명 주석은 작성하지 않는다.

---

## 변수 전략 (locals vs variable)

- **`environments/` (root module)**: `local`을 기본으로 사용한다. `variable`은 CI/CD 외부 주입이 필요하거나 민감한 값인 경우에만 허용한다.
- **`modules/`**: 호출자와의 인터페이스이므로 `variable`을 사용한다.
- `locals.tf`에 값을 직접 쓰는 것은 하드코딩이 아니라 올바른 집중 관리다.

---

## 변수 품질 (variable 사용 시)

- 모든 `variable`에 `description`을 작성한다.
- 입력값 검증이 필요한 변수에는 `validation` 블록을 추가한다.
- 민감한 값(인증서, 비밀번호 등)을 담는 `output`에는 `sensitive = true`를 설정한다.

---

## 안전성

- 삭제되면 안 되는 리소스(S3, DynamoDB, RDS 등)에는 `lifecycle { prevent_destroy = true }`를 적용한다.
- 노드 그룹 등 교체가 필요한 리소스에는 `lifecycle { create_before_destroy = true }`를 적용한다.
- 공식 모듈 (terraform-aws-modules, aws-ia 등) 버전은 `~> X.Y.Z` 형식(패치만 허용)으로 제약한다.
- Provider (hashicorp/aws 등) 버전은 `~> X.Y` 형식(마이너까지 허용)으로 제약한다.

---

## 버전 관리

### 공식 모듈 / Provider
| 대상 | 형식 | 이유 |
|------|------|------|
| 공식 모듈 (terraform-aws-modules, aws-ia 등) | `~> X.Y.Z` | 마이너도 인터페이스 변경 위험. 마이너 업그레이드는 CHANGELOG 확인 후 의도적으로 수동 변경 |
| Provider (hashicorp/aws, kubernetes 등) | `~> X.Y` | 마이너는 기능 추가만, breaking change는 메이저에서만 발생 |

### 커스텀 모듈 — 디렉토리 기반 버전 관리
커스텀 모듈은 `modules/{name}/{version}/` 디렉토리 구조로 관리한다.

```
modules/
  vpc/
    1.0.0/    ← 현재 버전
    2.0.0/    ← 공식 모듈 major 업그레이드 등 인터페이스 변경 시 생성
  eks/
    1.0.0/
```

**새 버전 디렉토리 생성 기준**
- 공식 모듈 major 업그레이드에 따른 인터페이스 변경
- variable 명칭 변경, 삭제 등 파괴적 변경

**현재 버전 내 수정 (새 디렉토리 불필요)**
- 버그 수정, 내부 구현 변경 (인터페이스 동일)
- 하위 호환되는 variable/기능 추가

환경에서 참조 시: `source = "../../../../../modules/vpc/1.0.0"`
기존 환경은 source 경로를 바꾸지 않는 한 이전 버전을 계속 사용하므로, 신규 리소스와 레거시 리소스 간 버전 격리가 가능하다.

---

## 모듈 작성 원칙

- `terraform-aws-modules`처럼 검증된 커뮤니티 모듈을 래핑하는 방식을 기본으로 한다.
- 모듈 인터페이스(variables / outputs)는 호출자가 필요한 것만 노출한다.
- 모듈 내부에서 provider를 직접 선언하지 않는다 (호출자에서 전달).
- 리소스별 설계 원칙은 해당 모듈 디렉토리의 `CLAUDE.md`를 참조한다.
