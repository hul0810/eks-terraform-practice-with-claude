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
- **태그 거버넌스 3계층 구조** (상세: `@docs/tag-governance.md`):
  - AWS Organizations Tag Policy → 허용값 정의 및 AWS 수준 컴플라이언스 리포팅
  - `tag_policy_compliance = "error"` → Terraform plan 시 태그 키 부재 차단
  - `validate_tags` precondition → Terraform plan 시 태그 값 위반 차단 (허용값은 tag-policy remote state에서 읽음)
- 신규 root module 작성 시 위 3계층 구성 필수 (`@docs/tag-governance.md` 체크리스트 참조)

---

## 코드 품질

- **동적 메타데이터 활용**: 리전, AZ, 계정 ID 등 AWS가 제공하는 메타데이터는 data source로 조회하며 하드코딩하지 않는다.
  - 가용 영역: `data "aws_availability_zones" { state = "available" }` → `.names`
  - 현재 리전: `data "aws_region" "current" {}` → `.name`
  - 계정 ID: `data "aws_caller_identity" "current" {}` → `.account_id`
  - 특정 AZ 예외(인스턴스 타입 미지원 등)는 data source 결과를 그대로 쓰되 해당 리소스에서 개별 필터링한다.
- **리소스 주소 안정성 — count vs for_each 선택 기준**:

  | 상황 | 패턴 | 이유 |
  |------|------|------|
  | 단순 on/off 토글 (0 또는 1개, 순서 무관) | `count = bool ? 1 : 0` | 공식 모듈 표준(aws-ia/eks-blueprints-addons 등). 재인덱싱 불가(최대 1개). |
  | 여러 개를 반복하거나 순서 영향이 있는 리소스 | `for_each = map/set` | 키 기반 stable address. 중간 삽입·삭제 시 후속 리소스에 영향 없음. |
  | 인라인 블록 (`ingress {}`, `egress {}` 등) | 별도 리소스로 분리 | 상위 리소스 전체 재생성 방지. |

  **count 사용 조건 (둘 다 충족해야 함)**:
  1. Boolean 토글 — 해당 리소스가 정확히 0개 또는 1개만 존재
  2. 순서 독립 — 같은 scope에 동일 타입 리소스가 여러 개 존재하지 않음

  **count 사용 금지 케이스**:
  - Security Group ingress/egress rule 목록 (`count = length(var.rules)` 형태)
  - `for_each` 맵 대신 배열을 순회하는 모든 경우

  ```hcl
  # ✅ count 올바른 사용 — 단일 on/off, 순서 무관
  resource "aws_eks_addon" "external_dns" {
    count = var.enable_external_dns ? 1 : 0
    ...
  }

  # ✅ for_each 올바른 사용 — 여러 개, 키 기반
  resource "aws_vpc_security_group_ingress_rule" "node" {
    for_each = var.ingress_rules   # map(object(...))
    ...
  }

  # ❌ count 잘못된 사용 — 목록 순회, 재인덱싱 위험
  resource "aws_vpc_security_group_ingress_rule" "node" {
    count = length(var.ingress_rules)
    ...
  }
  ```

- **공식 모듈 사용 시 리소스 생성 방식 사전 확인** (코드 작성 전 필수): 공식 모듈이 추가 리소스를 위한 파라미터를 제공하는 경우, 해당 파라미터의 내부 구현(`for_each` vs `count`)을 먼저 확인한다.

  | 모듈 내부 구현 | 판단 기준 | 대응 방식 |
  |--------------|----------|----------|
  | `for_each` 기반 (`map(object(...))` 타입 파라미터) | 안정적 → 모듈 파라미터 사용 | 모듈 파라미터로 전달 (외부 리소스 주입 금지) |
  | `count` 기반 (`list(object(...))` 또는 number 타입) | 불안정 → 외부 분리 필요 | 외부에 `for_each`-based 별도 리소스 선언 |
  | 파라미터 미제공 | 외부 분리 필요 | 외부에 `for_each`-based 별도 리소스 선언 |

  확인 방법: `terraform` MCP → `get_module_details`로 파라미터 type 조회.
  `map(object({...}))` 타입 → `for_each` 가능성 높음. 확신이 없으면 GitHub raw URL로 모듈 소스 직접 확인.
- **`depends_on` 최소화**: 암묵적 의존성(리소스 참조)을 최대한 활용한다.
- **`moved` 블록 활용**: 리소스 이름 변경이나 모듈 이동 시 state 이전에 사용한다.
- **주석**: WHY가 명확하지 않을 때만 한국어로 작성한다. WHAT 설명 주석은 작성하지 않는다.

---

## 협업 코드 작성 기준

코드는 혼자 작성하지만 협업 환경을 전제로 작성한다. 아래 기준은 선택이 아닌 의무다.

- **`variable` `description` 필수**: 없으면 호출자가 입력값의 의도를 알 수 없다. 코드 리뷰 반려 기준이다.
- **`output` 선언 의무**: 다른 root module이 참조하는 값은 반드시 `outputs.tf`에 선언한다. 선언하지 않으면 `terraform_remote_state`로 참조할 수 없다.
- **리소스 명명**: 이름만으로 환경·목적·대상을 파악할 수 있어야 한다. 약어를 사용할 경우 `CLAUDE.md`에 정의한다.
- **`sensitive` 출력 명시**: 인증서, 비밀번호 등 민감한 값을 담는 `output`에는 `sensitive = true`를 설정한다. 미설정 시 plan/apply 로그에 노출된다.

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

### EKS 관리형 Add-on

| 대상 | 형식 | 이유 |
|------|------|------|
| EKS 관리형 add-on (vpc-cni, kube-proxy, coredns 등) | `addon_version = "vX.Y.Z-eksbuildN"` 명시 고정 | `most_recent`는 apply 시점마다 버전이 달라져 환경 간 일관성 보장 불가 |

- 버전 선택 기준: `aws eks describe-addon-versions --kubernetes-version <k8s-ver>` 조회 후 EKS 권장(`defaultVersion: true`) 버전 사용
- 업그레이드: CHANGELOG 확인 후 `addon_version` 값을 의도적으로 수동 변경
- `most_recent = true` **사용 금지**

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

---

## 비용 최적화 설계 기본값

**핵심 원칙: 신규 리소스 작성 시 아래 기본값을 적용한다. 이탈 시 명시적 근거가 필요하다.**

### EKS

| 항목 | 기본값 | 이유 |
|------|--------|------|
| 클러스터 버전 | Standard Support 내 최신 버전 | Extended Support 진입 시 +$0.60/hr (+$438/월) |
| 버전 업그레이드 주기 | Standard Support 종료 60일 전 | Extended Support 누적 지출 방지 |
| 노드그룹 구매 옵션 | Spot 우선, On-Demand 최소화 | Spot은 On-Demand 대비 최대 70% 절감 |
| Karpenter NodePool | Spot → On-Demand 순 우선순위 | 중단 불가 워크로드만 On-Demand 지정 |
| 관리형 노드그룹 | system 노드풀은 On-Demand | CoreDNS 등 시스템 컴포넌트 안정성 보장 |

> EKS 버전 라이프사이클 확인: `aws eks describe-addon-versions` 또는 AWS 공식 문서

### NAT Gateway

| 항목 | 기본값 | 이유 |
|------|--------|------|
| develop 환경 | 단일 AZ에 NAT Gateway 1개 | 고가용성보다 비용 우선 ($0.059/hr × 대수) |
| production 환경 | AZ당 NAT Gateway 1개 | AZ 장애 시 트래픽 단절 방지 |
| AZ 간 트래픽 | 최소화 설계 | AZ 간 데이터 전송 $0.01/GB 추가 발생 |

> NAT Gateway 비용 구조: 시간 요금 $0.059/hr + 처리 데이터 $0.059/GB

### EC2 / 노드 인스턴스

| 항목 | 기본값 | 이유 |
|------|--------|------|
| EBS 볼륨 타입 | `gp3` | gp2 대비 20% 저렴, 동일 성능 기본 제공 |
| develop 인스턴스 클래스 | t-계열 (버스트 가능) | 낮은 기본 성능 + 버스트 = 비용 효율 |
| production 인스턴스 클래스 | m-계열 (범용) 또는 워크로드에 맞게 | 예측 가능한 성능 필요 시 |
| Savings Plans | 안정적 On-Demand 사용량에 적용 권장 | 1년 약정 시 최대 40% 절감 |

### RDS

| 항목 | 기본값 | 이유 |
|------|--------|------|
| Multi-AZ | `false` (develop), `true` (production) | develop은 단일 AZ로 비용 절반 |
| 인스턴스 클래스 | develop: `db.t3.*`, production: `db.m6g.*` | t3는 버스트 가능, 개발 환경에 적합 |
| 스토리지 타입 | `gp3` | gp2 대비 저렴, IOPS/throughput 독립 설정 |
| 자동 백업 보존 | develop: 1일, production: 7일 | 불필요한 스냅샷 스토리지 비용 방지 |

### CloudWatch Logs

| 항목 | 기본값 | 이유 |
|------|--------|------|
| `retention_in_days` | develop: 7, production: 30 | **미설정 시 무기한 보관** → 비용 무제한 누적 |
| 로그 그룹 생성 | 반드시 `retention_in_days` 명시 | 기본값 없음, 생략 불가 |

### S3

| 항목 | 기본값 | 이유 |
|------|--------|------|
| 스토리지 클래스 | `STANDARD` (자주 접근) / `INTELLIGENT_TIERING` (접근 패턴 불규칙) | Intelligent Tiering은 자동 계층 이동으로 최대 40% 절감 |
| Lifecycle 규칙 | 비현재 버전 보존: develop 3개, production 30일 | Versioning 활성화 시 구버전 무한 누적 방지 |
| 불완전 멀티파트 업로드 | 7일 후 중단 규칙 필수 | 완료되지 않은 업로드가 청구됨 |

### 비용 설계 체크리스트

신규 리소스 작성 시 아래 항목을 확인한다:

- [ ] EKS 버전이 Standard Support 기간 내인가?
- [ ] NAT Gateway 수가 환경 기준에 맞는가? (develop 1개 / production AZ당 1개)
- [ ] EBS 볼륨이 `gp3`인가?
- [ ] CloudWatch Log Group에 `retention_in_days`가 설정되어 있는가?
- [ ] RDS Multi-AZ가 환경에 맞게 설정되어 있는가?
- [ ] S3 Lifecycle 규칙이 설정되어 있는가?
- [ ] 장기 실행 On-Demand 리소스에 Savings Plans 적용 여부를 검토했는가?
