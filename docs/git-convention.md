# Git 컨벤션

## 브랜치 전략 (GitHub Flow)

### 브랜치 구조

| 브랜치 | 보호 | 역할 |
|--------|------|------|
| `main` | O | 항상 배포 가능한 상태 유지. 직접 push 금지 |
| `feature/<이름>` | X | 신규 기능 개발. PR로 main 병합 후 삭제 |
| `fix/<이름>` | X | 버그 수정. PR로 main 병합 후 삭제 |
| `hotfix/<이름>` | X | 긴급 수정. 신속 PR 후 삭제 |

### 브랜치 수명주기

```
main
  └─ feature/<이름> 분기
       └─ 작업 및 커밋
            └─ PR 생성 (feature → main)
                 └─ Squash and Merge
                      └─ feature 브랜치 삭제
```

### 브랜치 명명 예시

| 작업 | 브랜치명 |
|------|----------|
| VPC 모듈 ELB 태그 추가 | `feature/vpc-elb-subnet-tags` |
| EKS 노드 그룹 IAM 수정 | `fix/eks-node-iam-policy` |
| Karpenter 설정 긴급 수정 | `hotfix/karpenter-nodepool-limits` |
| .gitignore 정리 | `chore/update-gitignore` |

---

## 커밋 컨벤션 (Conventional Commits)

### 형식

```
<type>(<scope>): <한국어 설명>

[선택] 본문 (WHY 설명, 빈 줄 하나 후 작성)

[선택] BREAKING CHANGE: <내용>
```

### Type 정의

| type | 사용 시점 |
|------|----------|
| `feat` | 신규 리소스, 기능, 모듈 추가 |
| `fix` | 버그 수정, 설정 오류 수정 |
| `refactor` | 동작 변경 없는 코드 구조 개선 |
| `docs` | 문서 추가·수정 (`.md` 파일, 주석) |
| `chore` | 빌드 설정, `.gitignore`, MCP 설정 등 |
| `test` | 테스트 코드 추가·수정 |
| `ci` | CI/CD 파이프라인 변경 |

### Scope 정의

scope는 변경이 가장 집중된 디렉토리 이름으로 결정한다.

| scope | 대응 경로 |
|-------|----------|
| `vpc` | `modules/vpc/` |
| `eks` | `modules/eks/` |
| `karpenter` | `modules/karpenter/` |
| `eks-addons` | `modules/eks-addons/` |
| `rds` | `modules/rds/` |
| `develop` | `environments/develop/` |
| `production` | `environments/production/` |
| `shared` | `environments/{env}/{region}/shared/` |
| `tfstate` | `global/tfstate-backend/` |
| scope 없음 | 여러 영역에 걸친 변경, `.claude/`, `docs/` 변경 |

### 커밋 메시지 예시

```
feat(vpc): ELB 서브넷 태그 추가
fix(eks): 노드 그룹 IAM 권한 누락 수정
refactor(shared): locals.tf 변수 구조 개선
docs: git-convention 문서 추가
chore: .gitignore에 crash.log 패턴 추가
feat(karpenter): EC2NodeClass GPU 인스턴스 패밀리 추가
fix(production): provider assume_role ARN 오타 수정
```

### 커밋 메시지 규칙

- 설명은 한국어, 명령형(~추가, ~수정, ~개선, ~삭제, ~제거)으로 작성
- 제목 줄 50자 이하 권장, 72자 초과 금지
- 변경의 WHY가 불명확하면 본문에 이유 작성
- Breaking change는 본문에 `BREAKING CHANGE:` 명시

---

## PR 정책

### 생성 조건

- `feature/*`, `fix/*`, `hotfix/*` → `main`
- main에 직접 push 금지 (hotfix도 PR 경유)

### PR 제목

커밋 메시지와 동일한 형식 사용:

```
feat(vpc): ELB 서브넷 태그 추가
```

### PR 본문 템플릿

```markdown
## 변경 내용
- 변경 사항 bullet 요약

## Terraform Plan 결과
<!-- environments/prd/ 변경 시 plan 출력 첨부 필수 -->

## 체크리스트
- [ ] terraform fmt 적용 완료
- [ ] terraform validate 통과
- [ ] /review-terraform 리뷰 완료 (prd 변경 시)
```

### 병합 방식

**Squash and Merge 권장**: feature 브랜치의 작업 중 커밋(WIP 등)을 정리하고 main 이력을 간결하게 유지한다.

---

## 금지 사항

| 금지 행위 | 이유 |
|----------|------|
| `main` 직접 push | 검토 없는 변경으로 인한 장애 위험 |
| `git push --force` | 공유 이력 파괴 |
| `.tfstate` 파일 추적 | 민감 정보(ARN, IP 등) 노출 |
| `.terraform/` 디렉토리 추적 | 바이너리 제공자 파일, 용량 과다 |
| `.tfvars` 파일 추적 | 민감값 노출 위험 (`.tfvars.example`은 허용) |

---

## Terraform 특화 주의사항

### State Lock

동일한 root module 디렉토리에서 두 명 이상이 동시에 작업하면 DynamoDB state lock 충돌이 발생한다. 작업 시작 전 같은 `{env}/{region}/{project}/{resource}` 경로를 편집 중인 사람이 있는지 반드시 확인한다. 충돌 시 state 손상으로 이어질 수 있다.

### 작업 순서

```
plan 확인 → 리뷰 (prd) → apply
```

plan 없이 apply 금지. prd 환경 변경 시 반드시 `/review-terraform` 실행.

### 단독 PR 원칙

provider 버전 범프, 대규모 리팩토링은 기능 변경과 함께 커밋하지 않고 전용 PR로 분리한다. 혼합 커밋은 리뷰어가 변경 범위를 파악하기 어렵고, 롤백 단위가 모호해진다.

---

## `.terraform.lock.hcl` 정책

Git으로 추적한다. HashiCorp 공식 권장 사항이자 실무 협업의 기본 조건이다.

추적하지 않으면 작업자마다 서로 다른 provider 버전을 사용하게 되어 apply 결과가 달라지고, 재현 불가능한 빌드 환경이 만들어진다. `.gitignore`에서 제외하지 않는다.
