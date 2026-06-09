# modules/ecr 설계 원칙

## 작성 범위 — README.md(자동 생성)와 겹치지 않게

같은 디렉토리의 `README.md`는 `terraform-docs`가 코드에서 자동 생성한다 (변수/출력값의 타입·기본값·필수 여부·설명 = WHAT).
**이 CLAUDE.md에 같은 정보를 다시 적지 않는다.** 여러 변수에 걸치거나 변수 단위로 쪼갤 수 없는 설계 결정만 여기에 남긴다.

---

## 리포지토리 명명 규칙

`{project}-{service}-{environment}` 패턴을 따른다.

```
eks-practice-msa-develop
eks-practice-api-production
```

이름은 모듈 호출 시 map key(`each.key`)가 그대로 ECR 리포지토리 이름이 된다.
`environments/.../ecr/locals.tf`에서 key를 정할 때 이 패턴을 준수해야
AWS 콘솔·ECR pull 명령에서 환경·서비스를 한눈에 구분할 수 있다.

---

## 핵심 설계 결정

### image_tag_mutability = IMMUTABLE (기본값)

CI/CD 파이프라인에서 `latest` 같은 동일 태그를 덮어쓰면 어떤 이미지가 배포되었는지 추적 불가능해진다.
IMMUTABLE로 설정하면 같은 태그 푸시 시 에러가 발생하여 의도치 않은 이미지 교체를 방지하고 배포 불변성을 보장한다.
롤백 시에도 특정 태그 = 특정 이미지 보장이 핵심 전제 조건이다.

### lifecycle policy 규칙 우선순위

두 규칙의 우선순위를 의도적으로 설계했다:

1. (priority 1) 태그 없는 이미지 N일 후 만료 — untagged 이미지를 먼저 정리
2. (priority 2) **tagged 이미지** 수 제한(`tagStatus="tagged"`, `tagPatternList=["*"]`)

rule 2에 `tagStatus="any"` 대신 `"tagged"`를 사용하는 이유:
- `"any"` 사용 시 untagged 이미지도 count 계산에 포함된다.
  예를 들어 untagged 5개 + tagged 8개인 상황에서 limit=10이면 tagged 이미지 3개가 삭제될 수 있다.
- `"tagged"` + `tagPatternList=["*"]`는 모든 태그를 가진 이미지만 계산하여 배포 이미지 보존이 보장된다.

`tagStatus="tagged"` 사용 시 `tagPatternList` 또는 `tagPrefixList` 중 하나를 반드시 지정해야 한다(`["*"]`는 전체 대상).

기본값 `lifecycle_tagged_count = 10`, `lifecycle_untagged_days = 14`는 develop 환경 비용 통제 목적이다.
production에서는 롤백 시나리오를 고려해 `tagged_count`를 늘리는 것을 권장한다 (예: 30).

### force_delete = false (기본값)

이미지가 있는 리포지토리를 실수로 삭제하는 것을 방지한다.
`terraform destroy` 또는 리포지토리 key 제거 시 ECR에 이미지가 남아 있으면 apply가 실패한다.
빈 리포지토리는 `false`여도 삭제 가능하다.
의도적으로 이미지를 포함한 채 삭제해야 할 때만 `true`로 변경한다.

### scan_on_push = true (기본값)

ECR Basic 스캔은 무료다. 이미지 푸시 시점에 자동으로 CVE를 감지하므로 기본 활성화한다.
Enhanced 스캔(Inspector2)은 추가 비용이 발생하므로 이 모듈 범위 밖에서 별도 활성화 결정이 필요하다.

### encryption_type = AES256 (기본값)

develop 환경 비용 절감 목적으로 AWS 관리형 AES256을 사용한다.
production에서 규정 준수(HIPAA, PCI-DSS 등) 또는 키 로테이션 정책이 요구되면 `KMS`로 변경하고
`repository_kms_key`로 CMK ARN을 지정한다 (모듈 파라미터는 지원하나 이 커스텀 모듈에서 현재 노출하지 않음 — 필요 시 variables.tf에 추가).

### attach_repository_policy 조건부 활성화

`read_access_arns`와 `read_write_access_arns`가 모두 비어 있으면 빈 정책 문서가 생성되어
terraform-aws-modules/ecr v3에서 apply 오류가 발생한다.
ARN이 하나라도 있을 때만 정책을 생성하도록 조건부로 처리한다.

---

## 리포지토리 추가/삭제 방법

`environments/.../ecr/locals.tf`의 `repositories` 맵에만 항목을 추가하거나 제거한다.
모듈 코드 수정 없이 map key가 안정적인 Terraform 리소스 주소(`module.repositories["key"]`)로 관리된다.

리포지토리 이름을 변경해야 할 경우(key 변경) 단순 삭제 후 재생성이 아니라
`moved` 블록으로 state 이전을 수행해야 불필요한 이미지 삭제를 방지할 수 있다.

---

## 알려진 제약사항

- 이 모듈은 private 리포지토리만 다룬다. Public ECR은 별도 모듈(`repository_type = "public"`)이 필요하다.
- lifecycle policy는 리포지토리당 하나만 존재한다. 서비스별로 다른 정책이 필요하면 map key별로 `lifecycle_untagged_days`/`lifecycle_tagged_count` 값을 다르게 설정한다.
- Cross-account pull이 필요한 경우 `read_access_arns`에 타 계정 역할 ARN을 전달하면 ECR repository policy가 자동 생성된다.
