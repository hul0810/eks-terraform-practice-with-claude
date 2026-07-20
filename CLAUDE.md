# 프로젝트 지시사항

## 언어 규칙

- 응답 언어: 한국어
- 코드 주석: 한국어
- 커밋 메시지: 한국어
- 변수명 / 함수명: 영어 (코드 표준 준수)

---

## 비용 정책

**핵심 원칙: 실무 중심 인프라를 구축하되 비용을 최우선으로 고려한다.**

- Terraform 코드 변경 후 `/cost-check` 실행 권장 (배포 전 예상 비용 delta 확인)
- production 변경은 `/git-commit` 시 `/review-terraform`이 자동 실행되어 비용 체크 포함 4단계 리뷰 진행
- EKS 버전 지원 일정 필수 확인: Extended Support 진입 시 $0.50/hr 추가 발생
- 실제 비용 이상 감지 또는 원인 분석 필요 시: `cost-engineer` 에이전트에게 요청

---

## 협업 원칙

**핵심 선언: 비용 최적화 예외 항목을 제외한 모든 코드·문서·프로세스는 실무 협업 기준을 기본값으로 한다.**

비용 예외 항목 (단일 작업 환경으로 인해 의도적으로 단순화):
- develop 환경 NAT Gateway 단일 AZ
- develop 환경 t-계열 인스턴스 사용
- develop/monitoring 환경 시스템 노드 그룹 SPOT 용량 (Karpenter가 SPOT 중단으로 죽으면 클러스터
  자가 회복 능력이 상실되는 리스크를 실습 환경 한정으로 감수, `modules/eks/1.0.0/CLAUDE.md` 참조)
- production 환경 시스템 노드 그룹 min/desired=1 (HA 비활성화, `eks/locals.tf`에 복원 방법 주석)
- production 환경 NAT Gateway 단일 구성 (`single_nat_gateway = true`, `vpc/locals.tf`에 복원 방법 주석)

위 항목을 제외한 모든 영역의 기준:

| 영역 | 협업 기준 |
|------|----------|
| 코드 가독성 | 미래 작업자가 코드만으로 의도 파악 가능 (`description` 필수, WHY 주석) |
| 버전 고정 | `.terraform.lock.hcl` Git 추적, 모듈·provider 버전 명시 |
| 변경 추적 | 모든 변경은 PR 경유 (`main` 직접 push 금지) |
| 리뷰 프로세스 | production 변경 커밋 시 `/review-terraform` 필수 (`/git-commit` Step 4에서 자동 실행) |
| State 충돌 방지 | 동일 root module 동시 편집 금지, `plan` 확인 후 `apply` |
| 모듈 인터페이스 | `variable` `description` 필수, `sensitive` output 명시 |

---

## MCP 사용 규칙

- **Terraform 코드 작성 시**: `terraform` MCP로 provider/모듈 버전 및 리소스 스키마를 확인한 후 작성한다.
- **AWS 인프라 구축 시**: `aws-knowledge-mcp-server` MCP로 서비스 문서 및 베스트 프랙티스를 확인한다.
- **비용 조회 시**: `awslabs.billing-cost-management-mcp-server` MCP로 실제 청구 데이터, 이상 감지, 최적화 추천을 조회한다.
- 상세 조회 순서 및 규칙: `docs/terraform-principles.md` 참조

---

## Production 배포 정책

**`project/environments/production/` 경로에서 `terraform apply`는 Claude가 직접 실행하지 않는다.**

이 지시는 실수로 인한 운영 환경 변경을 방지하기 위한 것이다. 아래 절차를 따른다:

1. 코드 작성 → `/git-commit` 실행 (Step 4에서 `/review-terraform` 자동 실행)
2. PR 생성 → 팀 검토 및 승인
3. 사용자가 터미널에서 직접 `terraform apply` 실행

> 이 지시사항만으로는 강제 보장이 불가능하므로, `.claude/hooks/block-production-apply.sh` 훅이
> `PreToolUse` 이벤트에서 production apply를 하드 차단한다.
>
> `/env-provision production` / `/env-teardown production`도 예외가 아니다 — 이 훅은 어떤
> 도구가 호출했는지 구분하지 않고 `environments/production` 경로의 `terraform apply`를
> 기본적으로 차단한다. 즉 두 스킬은 production 환경명·root 디렉토리를 인식하고 절차를 안내하지만,
> 실제 apply 단계에서는 훅에 막혀 중단되고 사용자가 직접 실행해야 한다.
>
> **예외 — teardown 실습 목적의 임시 우회 마커**: production도 결국 실습 환경이므로 삭제(destroy)는
> 항상 가능해야 한다는 원칙에 따라, `terraform destroy`는 애초에 이 훅의 정규식 대상이 아니라
> 차단되지 않는다. 다만 teardown 절차 중 NAT Gateway 비활성화처럼 `terraform apply`가 필요한
> 단계가 있다 (`docs/environment-teardown.md` 참조). 이 경우 명령 앞에
> `ALLOW_PRODUCTION_TEARDOWN_APPLY=1` 마커를 붙이면 그 명령 1회에 한해 통과된다 (세션 전역
> 환경변수나 설정 변경이 아니라 커맨드 문자열 단위 마커이므로 트랜스크립트에 그대로 남아 감사
> 가능하고, 되돌리는 걸 깜빡할 위험이 없다). **이 마커는 teardown 실습 목적으로만 사용한다 —
> 일반 production 변경 배포에는 절대 붙이지 않는다.**

---

## 문서 동기화 원칙

**코드가 설명하지 못하는 설계 결정·제약·WHY는 문서에 기록한다.**

`.tf` 파일 변경 후 아래 규칙으로 확인할 문서를 탐색한다:

- `modules/{name}/CLAUDE.md`: 변경된 모듈의 CLAUDE.md — 항상 확인 (모든 모듈이 보유하는 구조 규칙)
- `docs/` 하위 문서: 변경된 모듈명·리소스 유형과 연관성이 높은 파일을 탐색하여 확인

**판단 기준** — 아래 중 하나라도 해당하면 문서를 수정한다:
- 이 변경의 "왜"를 코드만으로 파악할 수 없다
- 새로운 설계 결정·제약·패턴이 도입됐다
- 기존 문서 기술이 현재 코드와 달라졌다

`/git-commit` 스킬이 Step 3.5에서 이 판단을 수행하고 필요 시 직접 수정한다.

---

## Terraform 작성 지시사항

상세 원칙 전체: `docs/terraform-principles.md` 참조
**핵심 철학**: 초기에 올바른 구조를 갖춘다. 설정 비용이 낮고 장기 효과가 높다면 현재 규모와 관계없이 확장 가능한 구조를 기본값으로 선택한다.

핵심 요약:
- 환경별 설정값은 `locals.tf`에 집중 관리. `terraform.tfvars` 사용 금지
- 태그: `environment` / `managed_by` 2개만, 소문자
- 태그 거버넌스: `docs/tag-governance.md` 참조 (신규 root module 작성 시 3계층 구성 필수)
- 리소스 주소 안정성: `for_each` 기반 관리 필수, `count` 및 인라인 블록 금지. 공식 모듈 사용 시 `for_each` 파라미터 제공 여부 사전 확인 후 모듈 파라미터 또는 별도 리소스 결정 (`docs/terraform-principles.md` → 리소스 주소 안정성 섹션)
- `depends_on` 최소화, `moved` 블록으로 state 이전
- 삭제 불가 리소스: `lifecycle { prevent_destroy = true }`
- 공식 모듈 버전: `~> X.Y.Z` 형식 (패치만 허용)
- Provider 버전: `~> X.Y` 형식 (마이너까지 허용)
- 커스텀 모듈: 루트 `modules/{name}/{version}/` 디렉토리 구조 (예: `modules/vpc/1.0.0/`), 모든 프로젝트가 공유

---

## 에이전트 활용 가이드

**핵심 원칙: 작업 성격이 아래 트리거 조건 중 하나라도 해당하면 즉시 해당 에이전트에 위임한다. 직접 처리하지 않는다.**

### 능동적 위임 규칙 (자동 호출 트리거)

| 트리거 조건 | 위임 에이전트 | 연동 스킬 |
|------------|-------------|---------|
| `.tf` 파일 신규 작성·모듈 생성·리팩토링 요청 | `terraform-writer` | `git-commit`, `cost-check` |
| Terraform 코드 리뷰·Best Practice 검토 요청 | `terraform-reviewer` | `code-review`, `simplify` |
| IAM·네트워크·암호화·EKS 보안 검토 요청 | `security-engineer` | `security-review` |
| Well-Architected·EKS 설계·HA·DR 검토 요청 | `aws-architect` | `code-review` |
| Karpenter·add-on·Helm values·K8s 리소스 작업 | `kubernetes-specialist` | `code-review` |
| 비용 분석·이상 감지·최적화 제안 요청 | `cost-engineer` | `cost-check` |

> 각 에이전트는 `description`에 "proactively" 트리거 조건이 명시되어 있다.
> Claude는 description을 읽고 작업을 자동으로 위임한다.

### 에이전트 직접 호출 명령

| 에이전트 | 명령 | 모델 |
|----------|------|------|
| Terraform Writer | `/terraform-writer` | Sonnet |
| Terraform Reviewer | `/terraform-reviewer` | Sonnet |
| AWS Architect | `/aws-architect` | Opus (심층 분석) |
| Security Engineer | `/security-engineer` | Sonnet |
| Kubernetes Specialist | `/kubernetes-specialist` | Sonnet |
| Cost Engineer | `/cost-check` | Sonnet |

### 권장 작업 흐름

```
코드 작성 (terraform-writer) → git-commit + cost-check 스킬 자동 실행
  → 코드 리뷰 (terraform-reviewer) → code-review + simplify 스킬 활용
  → 보안 검토 (security-engineer) → security-review 스킬 활용
  → 아키텍처 리뷰 (aws-architect) → code-review 스킬 활용
  → 비용 리뷰 (cost-engineer) → cost-check 스킬 활용
```

`/git-commit` 실행 시 prd `.tf` 변경이 있으면 `/review-terraform` Skill이 자동 호출되어 위 4단계 리뷰(terraform-reviewer → security-engineer → aws-architect → cost-engineer)를 진행한다.

---

## 프로젝트 컨텍스트

- **폴더 구조 상세**: `docs/project-structure.md` 참조
- **Git 컨벤션**: `docs/git-convention.md` 참조
- **Terraform 원칙**: `docs/terraform-principles.md` 참조
- **태그 거버넌스**: `docs/tag-governance.md` 참조
- **모듈 CLAUDE.md 작성 기준**: `docs/module-claude-template.md` 참조
- **EKS 애드온 전략**: `docs/addon-strategy.md` 참조 (관리형 우선 원칙, 분류표, Pod Identity 패턴)
- **GitOps 원칙 정책**: `docs/gitops-principles.md` 참조 (OpenGitOps 4원칙, 부트스트랩 예외 판단 기준, 알려진 미충족 갭)
- **환경 전체 삭제 절차**: `docs/environment-teardown.md` 참조 (LBC ALB orphan 방지 순서, 수동 정리)
- **K8s 운영 팁**: `docs/k8s-operator-tips.md` 참조 (RBAC 확인 명령어, krew 설치/트러블슈팅 등 누적 기록)
- **Git 저장소**: https://github.com/hul0810/eks-terraform-practice-with-claude
- **GitOps 매니페스트 저장소**: https://github.com/hul0810/eks-practice-devops-manifest
  (Phase 5 — ArgoCD가 참조할 EKS 애드온 Helm values/ApplicationSet 매니페스트 관리)
- **애플리케이션 저장소**: https://github.com/hul0810/eks-practice-application-with-claude
  (EKS에 배포할 애플리케이션 코드 — Docker 이미지 빌드 대상)
- **목적**: 실무 기반 EKS + Terraform 인프라 구축 실습 (협업 가능한 구조를 기본값으로)
- **환경**: `develop` / `production` 2개
- **리전**: `ap-northeast-2` (서울)
- **오토스케일링**: Karpenter
- **모니터링**: Prometheus + Grafana (kube-prometheus-stack)
- **상태 관리**: S3 원격 백엔드 + 네이티브 락 (`use_lockfile = true`, Terraform 1.10+, DynamoDB 락 테이블 미사용)
