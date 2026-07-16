# {모듈명} 모듈 설계 가이드

> 새 모듈 추가 시 이 파일을 복사하여 `modules/{name}/{version}/CLAUDE.md`로 저장한다.
> 공통 Terraform 원칙(`docs/terraform-principles.md`)은 여기서 반복하지 않는다.
> 이 모듈에서만 적용되는 특이사항과 설계 결정만 기록한다.

---

## 작성 범위 — README.md(자동 생성)와 겹치지 않게

같은 디렉토리의 `README.md`는 `terraform-docs`가 코드에서 자동 생성한다 (변수/출력값의 타입·기본값·필수 여부·설명 = WHAT). **이 CLAUDE.md에 같은 정보를 다시 적지 않는다** — 정보별 단일 진실 공급원 원칙(상세: `docs/terraform-principles.md` → 모듈 문서화)에 따라 아래처럼 나눠 적는다.

- **변수 하나로 설명되는 WHY** → 이 파일이 아니라 `variable`/`output`의 `description`에 직접 쓴다. terraform-docs가 README에 그대로 노출한다.
  - 예: `variable "project"`의 description에 "cluster_name 대신 사용하는 이유: cluster_name은 길어지면 IAM role name_prefix 38자 한도를 초과하기 때문"까지 포함해서 작성 → README Inputs 표에 자동 노출됨
- **모듈/Provider 버전 같은 단순 사실** → 적지 않는다. README의 `Modules`/`Providers` 섹션이 `.tf`/`.terraform.lock.hcl`에서 직접 추출한다 (수동 기재는 drift만 만든다). 이 파일에는 "왜 이 버전에 고정했는지"·"업그레이드 시 무엇이 바뀌는지"만 남긴다.
- **여러 변수에 걸치거나 변수 단위로 쪼갤 수 없는 설계 결정** → 이 파일에 남긴다 (아래 섹션들).

---

## 핵심 설계 원칙

이 모듈에서 반드시 지켜야 할 설계 결정을 기록한다.
WHY 중심으로 작성한다 — "무엇"은 코드가 설명하므로 "왜 이렇게 결정했는가"를 남긴다.

예시:
- Public 서브넷에 NAT Gateway를 배치하는 이유: Private 서브넷의 아웃바운드 인터넷 트래픽 처리

---

## 리소스 명명 규칙

이 모듈에서 생성하는 리소스의 이름 패턴을 정의한다.

예시:
- 서브넷: `{vpc_name}-{type}-{az_abbr}` (예: `prod-vpc-private-apne2-az1`)
- AZ 약어: `ap-northeast-2a` → `apne2-az1`

---

## 종합적 설계 트레이드오프

여러 변수·리소스에 걸쳐 있어 단일 `description`으로 표현할 수 없는 결정 기준을 기록한다.
(단일 변수로 설명되는 WHY는 여기 대신 해당 `variable`/`output`의 `description`에 작성 — 위 "작성 범위" 참조)

예시:
- Database 서브넷: 별도 라우팅 테이블 필수 (`create_database_subnet_route_table = true`) — RDS가 Private 서브넷과 다른 라우팅 정책을 요구하기 때문

---

## 알려진 제약사항 / 예외

특정 AZ 미지원 인스턴스, 서비스 한도, 특수 라우팅 등 예외 케이스를 기록한다.

예시:
- `ap-northeast-2c` AZ는 일부 인스턴스 타입 미지원 — 해당 리소스에서 개별 필터링
- S3 Gateway Endpoint는 Public 서브넷에 연결하지 않음 (Public은 IGW 통해 직접 접근)
