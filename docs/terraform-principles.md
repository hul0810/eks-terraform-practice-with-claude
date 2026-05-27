# Terraform 작성 원칙

## MCP 사용 순서

### Terraform 코드 작성 시
- `get_latest_provider_version` → `get_provider_capabilities` → `get_provider_details` 순서로 조회한다.
- 모듈 사용 시 `get_latest_module_version`으로 최신 버전을 확인한다.
- **모든 AWS provider에 `assume_role`을 반드시 포함한다.**
  - profile: `terraform`
  - role_arn: `arn:aws:iam::891396992584:role/TerraformExecutionRole`

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
- Provider 버전은 `~> X.Y` 형식(마이너 버전 고정)으로 제약한다.

---

## 모듈 작성 원칙

- `terraform-aws-modules`처럼 검증된 커뮤니티 모듈을 래핑하는 방식을 기본으로 한다.
- 모듈 인터페이스(variables / outputs)는 호출자가 필요한 것만 노출한다.
- 모듈 내부에서 provider를 직접 선언하지 않는다 (호출자에서 전달).
- 리소스별 설계 원칙은 해당 모듈 디렉토리의 `CLAUDE.md`를 참조한다.
