---
name: git-commit
description: >
  Git 변경사항을 분석하여 Conventional Commits + 한국어 형식으로 커밋 메시지를
  자동 생성하고 스테이징·커밋·(선택적) push를 수행한다.
  원자적 커밋 강제(scope 그룹 분리), 변경 영향 분석(resource 추가/수정/삭제),
  Breaking Change 감지, Terraform 품질 체크 안내, PR 가이드 포함.
  모듈 variables.tf/outputs.tf 변경 시 terraform-docs로 README 자동 재생성.
  브랜치 정책 검증, main 직접 커밋 차단, .tf 변경 시 review-terraform 선행 실행.
  docs/git-convention.md의 규칙을 기준으로 동작한다.
disable-model-invocation: false
allowed-tools:
  - Bash(git status)
  - Bash(git diff)
  - Bash(git diff --staged)
  - Bash(git diff --name-only)
  - Bash(git diff --name-only HEAD)
  - Bash(terraform-docs *)
  - Bash(git branch --show-current)
  - Bash(git log --oneline -5)
  - Bash(git add -A)
  - Bash(git add *)
  - Bash(git commit -m *)
  - Bash(git push *)
  - Bash(git checkout -b *)
  - Read
  - Glob
---

## 실행 절차

아래 순서를 반드시 지킨다.

### Step 0: 브랜치 확인 및 정책 검증

`git branch --show-current`로 현재 브랜치를 확인한다.

**main 브랜치인 경우**: 커밋을 중단하고 사용자에게 경고한다.

```
[경고] main 브랜치에 직접 커밋하는 것은 GitHub Flow 정책에 위배됩니다.
feature/*, fix/*, hotfix/* 브랜치를 생성한 후 재시도하세요.
새 브랜치를 생성할까요?
```

- 사용자가 브랜치 생성에 동의하면: 브랜치 이름을 물어보고 `git checkout -b <이름>` 실행 후 Step 1로 진행
- 사용자가 강제 진행을 명시적으로 요청한 경우에만 main에서 계속 진행
- 그 외 응답이면 작업 종료

**main 외 비표준 브랜치인 경우**: 경고만 출력하고 계속 진행한다.

```
[안내] 브랜치명 '<이름>'이 feature/*, fix/*, hotfix/* 형식이 아닙니다.
계속 진행합니다.
```

### Step 1: 변경 파일 분석

`git status`와 `git diff --name-only HEAD`를 실행하여 변경 파일 목록을 파악한다.

**scope 추론 규칙** (변경이 집중된 경로 기준):

| 변경 경로 패턴 | scope |
|---------------|-------|
| `modules/vpc/` | `vpc` |
| `modules/eks/` | `eks` |
| `modules/karpenter/` | `karpenter` |
| `modules/eks-addons/` | `eks-addons` |
| `modules/rds/` | `rds` |
| `project/environments/develop/` | `dev` |
| `project/environments/production/` | `prd` |
| `global/tfstate-backend/` | `tfstate` |
| `.claude/`, `docs/`, `CLAUDE.md` 등 | scope 없음 |

**type 결정 기준**:

| 변경 성격 | type |
|----------|------|
| 신규 리소스·기능·모듈 추가 | `feat` |
| 버그 수정, 설정 오류 수정 | `fix` |
| 동작 변경 없는 구조 개선 | `refactor` |
| 문서 추가·수정 | `docs` |
| 빌드 설정, .gitignore, MCP 등 | `chore` |
| CI/CD 변경 | `ci` |

**scope 그룹 계산** (Step 2에서 사용):

변경 파일 목록을 아래 규칙으로 그룹화한다.

| 경로 패턴 | 그룹 |
|----------|------|
| `modules/<name>/` 하위 | `MODULE:<name>` |
| `project/environments/develop/` 하위 | `ENV:develop` |
| `project/environments/production/` 하위 | `ENV:production` |
| `global/` 하위 | `GLOBAL` |
| `docs/`, `.claude/`, 루트 파일 | `META` |

### Step 1.5: 모듈 인터페이스 문서 자동 재생성 (terraform-docs)

Step 1에서 파악한 변경 파일 중 `modules/{name}/{version}/variables.tf` 또는 `outputs.tf`가 있는 경우 실행한다. 없으면 건너뛴다.

저장소 루트의 `.terraform-docs.yml`을 모든 모듈이 공유하므로 별도 옵션 없이 실행한다:

```bash
terraform-docs modules/{name}/{version}
```

`README.md`는 코드에서 추출한 인터페이스 레퍼런스(WHAT)만 담는 자동 생성물이다 — Step 3.5의 `CLAUDE.md`(WHY) 판단과 달리 사람의 판단이 개입할 여지가 없으므로, **사용자 확인 없이 즉시 재생성**하고 변경 파일 목록에 포함시켜 이후 단계(스테이징·커밋)에서 함께 다룬다. (Step 1에서 계산한 `MODULE:<name>` 그룹에 자연스럽게 포함된다.)

```
[모듈 문서 재생성]
modules/eks/1.0.0/README.md 재생성 완료 (terraform-docs)
```

`git diff --name-only`로 실제 변경이 발생했는지 확인한다 — description 변경 등 표시 내용에 영향이 없으면 README.md는 변경되지 않으므로 스테이징 대상에서 자연히 제외된다.

### Step 2: 원자성 검사 및 분리 전략 제안

Step 1에서 계산한 scope 그룹이 2개 이상이면 아래 로직을 실행한다.

**분리 강력 권고 케이스** (반드시 분리를 권고):
- `MODULE:X` + `ENV:develop` 또는 `ENV:production` → 모듈 변경과 환경 적용은 별도 커밋
- `ENV:develop` + `ENV:production` → develop 검증 없는 production 동시 변경 (강력 경고)
- `MODULE:X` + `MODULE:Y` (X≠Y) → 서로 다른 모듈은 별도 커밋

**분리 선택 케이스** (제안하되 사용자 선택):
- `.tf` 파일 + `.md` 파일 혼재

분리 권고 시 아래 형식으로 출력한다:

```
[원자적 커밋 권고]
변경된 파일이 여러 작업 단위에 걸쳐 있습니다:

  그룹 1 (MODULE:vpc) - 2개 파일
    modules/vpc/main.tf
    modules/vpc/variables.tf

  그룹 2 (ENV:develop) - 1개 파일
    project/environments/develop/ap-northeast-2/shared/vpc/locals.tf

독립적인 롤백을 위해 분리 커밋을 권고합니다.

[선택]
  1) 그룹 1만 지금 커밋, 그룹 2는 다음 커밋으로 분리 (권장)
  2) 모두 하나의 커밋으로 진행
  3) 포함할 파일을 수동으로 선택
```

- 사용자가 **1 선택**: 그룹 1 파일 목록을 스테이징 대상으로 기록, Step 9에서 잔여 파일 안내
- 사용자가 **2 선택**: 분리 없이 진행
- 사용자가 **3 선택**: 변경 파일 목록을 번호로 나열하고 포함할 파일을 선택받음

scope 그룹이 1개이거나 META/GLOBAL만 혼재하면 이 단계를 건너뛴다.

### Step 3: 변경 영향 분석

`git diff`를 읽어 Terraform 변경 정보를 추출한다. 결과는 Step 5 커밋 메시지 본문 생성에 사용한다.

**리소스 변경 추출 패턴**:

| diff 패턴 | 분류 |
|-----------|------|
| `+resource "aws_*" "*" {` | [추가] 리소스 |
| `-resource "aws_*" "*" {` | [삭제] 리소스 |
| `+module "<name>"` | [추가] 모듈 호출 |
| resource/module 블록 내부 변경 (`+`/`-` 라인 혼재) | [수정] 리소스/모듈 |

**Breaking Change 플래그 조건** (하나라도 해당하면 BREAKING_CHANGE=true):
- 아래 immutable attribute 값이 변경된 경우:
  - `cidr_block`, `vpc_cidr`, `azs`, `availability_zone`
  - `cluster_name` (EKS), `identifier` (RDS)
- `prevent_destroy = true` 리소스에서 `-resource` 패턴 감지
- `project/environments/production/`에서 resource 블록 삭제

**moved 블록 권고 조건** (MOVED_WARNING=true):
- 동일 resource type에서 `-resource "T" "old"` + `+resource "T" "new"` 패턴 동시 감지

.tf 파일 변경이 없으면 이 단계를 건너뛴다.

### Step 3.5: 문서 동기화 판단 및 수정

변경된 `.tf` 파일 중 `modules/` 하위 파일이 있는 경우 실행한다. 없으면 건너뛴다.

**확인 문서 탐색**:

1. `modules/{name}/CLAUDE.md`: 변경된 모듈의 CLAUDE.md — 항상 확인
2. `docs/` 디렉토리를 Glob으로 탐색하여 변경된 모듈명·리소스 유형과 연관성이 높은 문서를 찾는다
   (예: `modules/rds/` 변경 시 `docs/rds-*.md`, `modules/eks/` 변경 시 `docs/addon-*.md` 등)

**판단 절차**:

1. 체크 대상 문서를 Read 도구로 읽는다.
2. diff와 문서를 비교하여 아래 세 가지 질문에 스스로 답한다:
   - 이 변경의 "왜"를 코드만으로 파악할 수 없는 부분이 있는가?
   - 새로운 설계 결정·제약·패턴이 도입되어 문서에 반영되지 않았는가?
   - 기존 문서 기술이 현재 코드와 달라진 부분이 있는가?

3. 하나라도 "예"이면 → 문서를 직접 수정한 뒤 아래를 출력한다:

```
[문서 동기화]
modules/eks/1.0.0/CLAUDE.md 수정:
  - (수정한 내용을 구체적으로 기술)

[선택]
  1) 이번 커밋에 포함
  2) 별도 커밋으로 분리 (Step 9에서 잔여 파일로 안내)
```

- **1 선택**: 수정된 문서를 스테이징 대상에 포함한다.
- **2 선택**: 현재 커밋은 계속 진행하고, Step 9에서 미수정 문서를 "다음 커밋" 잔여 항목으로 안내한다.

4. 모두 "아니오"이면:

```
[문서 동기화] 동기화 불필요
```

### Step 4: review-terraform 실행

변경 파일 중 `.tf` 파일이 있는 경우 반드시 실행한다. `.tf` 파일이 없으면 건너뛴다.

`/review-terraform` 스킬을 Skill 도구로 호출하여 코드 리뷰를 완료한다.

리뷰가 완료될 때까지 Step 5로 진행하지 않는다.

리뷰 결과에서 치명적 문제(보안 취약점, Breaking Change, 비용 이상)가 발견된 경우:
- 문제 내용을 사용자에게 보고하고 수정 여부를 확인한다.
- 사용자가 수정 후 재진행하거나 명시적으로 진행을 승인하면 Step 5로 넘어간다.

### Step 5: 커밋 메시지 초안 생성 및 사용자 확인

**형식**: `<type>(<scope>): <한국어 설명>`

**제목 규칙**:
- 설명은 한국어, 명령형(~추가, ~수정, ~개선, ~삭제, ~제거)
- 제목 줄 72자 이하 (50자 권장)
- 파일명 나열 금지 (본문에 포함)

**커밋 메시지 작성 원칙 (협업자 관점)**:
커밋 메시지는 코드 변경 내역이 아니라 **작업의 맥락과 의도**를 전달한다.
협업자가 커밋 메시지만 읽고 "왜 이 작업을 했는지", "무엇이 바뀌었는지"를 한 눈에 파악할 수 있어야 한다.

- **제목**: 변경의 핵심을 한 줄로 — 단순 파일명·기능명 나열 금지. 작업의 목적이 드러나야 한다.
  - 나쁜 예: `feat(dev): validate_tags 추가`
  - 좋은 예: `feat(dev): 태그 값 위반 시 plan 단계에서 즉시 차단 — validate_tags precondition 도입`
- **본문 Terraform 변경**: 리소스 이름만 나열하지 않는다. 각 변경이 무엇을 달성하는지 한 줄 설명을 덧붙인다.
- **WHY**: 변경 이유가 자명하지 않으면 반드시 작성한다. "왜 이렇게 했는가"가 없으면 미래의 작업자가 롤백 여부를 판단할 수 없다.

**본문 자동 생성** (Step 3 결과 활용):

```
feat(vpc): ELB 서브넷 태그 추가 — EKS ALB/NLB 서브넷 자동 탐색 지원

변경 파일:
- modules/vpc/main.tf

Terraform 변경:
- [수정] module.vpc: public_subnet_tags, private_subnet_tags 추가
    EKS가 서브넷을 자동으로 탐색할 때 kubernetes.io/* 태그를 기준으로 필터링한다.

WHY: 태그 없이 배포하면 ALB Ingress Controller가 서브넷을 인식하지 못해
     LoadBalancer 서비스가 생성되지 않는다. 태그 추가로 이 문제를 사전 방지한다.
```

- WHY는 변경 이유가 코드만으로 명확하지 않을 때 반드시 작성한다.
- Terraform 변경 목록이 없으면 (문서·설정 변경 등) 해당 섹션을 생략한다.

**Breaking Change 감지 시** 본문 끝에 자동 추가:

```
BREAKING CHANGE: <immutable attribute> 변경으로 리소스 재생성이 발생할 수 있습니다.
terraform plan으로 영향을 반드시 확인하세요.
```

**moved 블록 권고 시** 본문 끝에 자동 추가:

```
[주의] 리소스 이름 변경이 감지되었습니다. moved 블록을 추가하지 않으면 재생성됩니다.
  moved {
    from = <old_ref>
    to   = <new_ref>
  }
```

초안을 다음 형식으로 사용자에게 제시한다:

```
제안된 커밋 메시지:
───────────────────
feat(vpc): ELB 서브넷 태그 추가

변경 파일:
- modules/vpc/main.tf

Terraform 변경:
- [수정] module.vpc (public_subnet_tags, private_subnet_tags 추가)
───────────────────
이대로 진행할까요? (수정이 필요하면 알려주세요)
```

사용자가 수정을 요청하면 수정된 메시지로 교체하고 재확인한다.

### Step 6: Terraform 품질 체크 안내

변경 파일 중 `.tf` 파일이 있는 경우에만 실행한다.

변경된 `.tf` 파일이 위치한 디렉토리를 파악한 후 아래 형식으로 **정보만 출력하고 바로 Step 7로 진행**한다. 사용자 확인을 기다리지 않는다.

```
[Terraform 품질 체크 권고]
□ terraform fmt      실행 위치: modules/vpc/
□ terraform validate 실행 위치: modules/vpc/
```

### Step 7: 파일 스테이징

변경 파일 목록을 사용자에게 표시한 후 스테이징한다.

**스테이징 금지 패턴** (감지 시 경고 후 제외):
- `*.tfstate`, `*.tfstate.backup`
- `.terraform/` 내 파일
- `*.tfvars` (`.tfvars.example` 제외)
- `.claude/.prd-changed`

**분리 커밋 선택 시** (Step 2에서 그룹 1 선택): 해당 그룹 파일만 `git add <파일>` 개별 스테이징

**전체 커밋 시**: `git add -A` (금지 패턴 제외)

사용자가 특정 파일을 지정한 경우: 해당 파일만 스테이징

### Step 8: 커밋 실행

`git commit -m "<메시지>"`를 실행한다.

커밋 성공 후:
1. `git log --oneline -3`으로 최근 커밋 3개를 출력한다.
2. "원격(origin)으로 push할까요?"를 묻는다.
   - 예: `git push origin <현재 브랜치>` 실행
   - 아니오: push 없이 Step 9로 진행

### Step 9: 완료 안내 및 후속 가이드

아래 항목을 조건에 따라 출력한다.

#### 9-1. PR 생성 가이드 (항상 출력)

```
[PR 생성 가이드]
PR 제목: feat(vpc): ELB 서브넷 태그 추가

체크리스트:
  [ ] terraform fmt 완료
  [ ] terraform validate 통과
  [ ] terraform plan 결과 확인 및 PR 본문에 첨부

PR 생성: https://github.com/hul0810/eks-terraform-practice-with-claude/compare/<현재 브랜치>
```

#### 9-2. State Lock 안내 (`environments/` 하위 `.tf` 변경 시)

```
[State 관리]
변경 대상 State: <env>/ap-northeast-2/<project>/<resource>/terraform.tfstate
terraform apply 전 팀에 공유하세요 (State Lock 충돌 방지).
```

#### 9-3. Cross-layer 의존성 안내 (`outputs.tf` 변경 감지 시)

```
[출력값 변경]
outputs.tf가 변경되었습니다.
이 모듈을 terraform_remote_state로 참조하는 상위 모듈의 plan도 확인하세요.
```

#### 9-4. 잔여 파일 안내 (Step 2에서 분리 커밋 선택 시)

```
[다음 커밋]
이번 커밋: MODULE:vpc 그룹 (2개 파일)
잔여 변경: ENV:develop 그룹 (1개 파일)
  - project/environments/develop/ap-northeast-2/shared/vpc/locals.tf

/git-commit을 다시 실행하여 다음 커밋을 진행하세요.
```
