# modules/sqs 설계 원칙

## 작성 범위 — README.md(자동 생성)와 겹치지 않게

같은 디렉토리의 `README.md`는 `terraform-docs`가 코드에서 자동 생성한다 (변수/출력값의 타입·기본값·필수 여부·설명 = WHAT).
**이 CLAUDE.md에 같은 정보를 다시 적지 않는다.** 여러 변수에 걸치거나 변수 단위로 쪼갤 수 없는 설계 결정만 여기에 남긴다.

---

## 큐 명명 규칙

`{project}-{service}-events{environment}` 패턴을 따른다.

```
eks-practice-order-events-dev
eks-practice-order-events
```

이름은 모듈 호출 시 map key(`each.key`)가 그대로 SQS 큐 이름이 된다.
`environments/.../sqs/locals.tf`에서 key를 정할 때 이 패턴을 준수해야
AWS 콘솔·큐 URL에서 환경·서비스·이벤트 종류를 한눈에 구분할 수 있다.

FIFO 큐를 사용하는 경우 key는 반드시 `.fifo`로 끝나야 한다 (AWS 하드 요구사항).
`variables.tf`의 validation 블록이 `fifo_queue` 값과 이름의 `.fifo` 접미사 일치 여부를
plan 단계에서 미리 검증한다 — apply 시점에야 실패하면 되돌리기 번거롭기 때문이다.

---

## 핵심 설계 결정

### Standard 큐를 기본값으로 (fifo_queue = false)

이 모듈이 감싸는 첫 사용처(order-events)를 포함해 대부분의 이벤트 발행 시나리오는
엄격한 순서 보장이나 정확히 한 번(exactly-once) 처리가 필요하지 않다.
Standard 큐는 월 100만 건까지 무료이고 처리량 제한이 사실상 없어 비용·운영 부담이 가장 낮다.
FIFO가 실제로 필요한 서비스(예: 순서가 중요한 결제 이벤트)가 생기면
그 서비스의 `locals.tf`에서 `fifo_queue = true`로 개별 활성화하면 된다 — 모듈 수정은 불필요하다.

### DLQ는 기본 비활성화 (create_dlq = false)

DLQ는 모든 큐에 일괄 강제하기보다 각 서비스가 재처리·알림 전략을 직접 설계한 뒤
필요할 때 개별적으로 켜는 것이 맞다고 판단했다. 이 모듈은 `create_dlq` 파라미터만 열어 두고
(`terraform-aws-modules/sqs/aws`가 내부적으로 DLQ 리소스와 redrive_policy를 자동 구성한다),
실제로 어떤 서비스가 DLQ를 켤지·maxReceiveCount를 얼마로 할지는 이 모듈의 관심사가 아니다.
현재(order-events)는 사용자가 메인 큐만 우선 생성하기로 결정해 `false`를 유지한다.

### sqs_managed_sse_enabled = true (기본값)

SQS 관리형 SSE는 추가 비용 없이 저장 데이터를 암호화한다. KMS CMK 암호화가 필요한
규정 준수 요구사항이 생기면 이 변수를 노출하는 대신 `kms_master_key_id`를 이 모듈에
추가로 노출하는 방향으로 확장한다 (현재는 사용처가 없어 노출하지 않음).

### visibility_timeout_seconds 등 나머지 값은 optional(number, null)로 모듈 기본값에 위임

이 커스텀 모듈이 자체 기본값을 다시 정의하지 않고 `null`을 그대로 넘겨
`terraform-aws-modules/sqs/aws`의 기본값(예: visibility_timeout 30초)을 따르게 한다.
두 곳에서 기본값을 관리하면 업스트림 기본값이 바뀌었을 때 이 모듈만 구버전 값에 고정되는
drift가 생기기 때문이다. 값 범위 검증(validation)만 이 모듈이 담당한다.

---

## for_each 설계

`terraform-aws-modules/sqs/aws`는 큐 하나당 모듈 인스턴스 하나를 생성하는 구조라
`for_each` 파라미터 자체를 제공하지 않는다 (map(object(...)) 타입 입력 없음).
따라서 `modules/ecr`와 동일하게 이 커스텀 모듈이 `for_each`로 감싸 map key를
stable Terraform 리소스 주소(`module.queues["key"]`)로 관리한다.

---

## 리소스 명명 규칙

- SQS 큐: `var.queues`의 map key를 그대로 큐 이름으로 사용 (`each.key`)

---

## 알려진 제약사항 / 예외

- DLQ 리소스는 모듈 파라미터(`create_dlq`)로만 존재하며 이 프로젝트에서 아직 실제로 켠 서비스가 없다.
- SQS queue policy(리소스 기반 정책)·IAM Role/IRSA/Pod Identity 연결은 이 모듈의 범위 밖이다.
  큐를 사용하는 서비스 root module 또는 별도 IAM 모듈에서 구성한다.
- FIFO 큐의 `content_based_deduplication`, `deduplication_scope`, `fifo_throughput_limit` 등은
  현재 사용처가 없어 노출하지 않는다. FIFO 큐가 실제로 필요해지면 그때 변수를 추가한다.
