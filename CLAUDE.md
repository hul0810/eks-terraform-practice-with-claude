# 프로젝트 지시사항

## 언어 규칙

- 응답 언어: 한국어
- 코드 주석: 한국어
- 커밋 메시지: 한국어
- 변수명 / 함수명: 영어 (코드 표준 준수)

---

## MCP 사용 규칙

- **Terraform 코드 작성 시**: `terraform` MCP로 provider/모듈 버전 및 리소스 스키마를 확인한 후 작성한다.
- **AWS 인프라 구축 시**: `aws-knowledge-mcp-server` MCP로 서비스 문서 및 베스트 프랙티스를 확인한다.
- 상세 조회 순서 및 규칙: `@docs/terraform-principles.md` 참조

---

## Production 배포 정책

**`environments/production/` 경로에서 `terraform apply`는 Claude가 직접 실행하지 않는다.**

이 지시는 실수로 인한 운영 환경 변경을 방지하기 위한 것이다. 아래 절차를 따른다:

1. 코드 작성 → `/review-terraform` 리뷰 완료
2. PR 생성 → 팀 검토 및 승인
3. 사용자가 터미널에서 직접 `terraform apply` 실행

> 이 지시사항만으로는 강제 보장이 불가능하므로, `.claude/hooks/block-production-apply.sh` 훅이
> `PreToolUse` 이벤트에서 production apply를 하드 차단한다.

---

## Terraform 작성 지시사항

상세 원칙 전체: `@docs/terraform-principles.md` 참조
**핵심 철학**: 초기에 올바른 구조를 갖춘다. 설정 비용이 낮고 장기 효과가 높다면 현재 규모와 관계없이 확장 가능한 구조를 기본값으로 선택한다.

핵심 요약:
- 환경별 설정값은 `locals.tf`에 집중 관리. `terraform.tfvars` 사용 금지
- 태그: `environment` / `managed_by` 2개만, 소문자
- 인라인 블록 금지 (Security Group rule, S3 설정 등 별도 리소스로 분리)
- `depends_on` 최소화, `moved` 블록으로 state 이전
- 삭제 불가 리소스: `lifecycle { prevent_destroy = true }`
- 공식 모듈 버전: `~> X.Y.Z` 형식 (패치만 허용)
- Provider 버전: `~> X.Y` 형식 (마이너까지 허용)
- 커스텀 모듈: `modules/{name}/{version}/` 디렉토리 구조 (예: `modules/vpc/1.0.0/`)

---

## 에이전트 활용 가이드

작업 성격에 따라 아래 에이전트를 호출한다. 에이전트 없이 작업할 때는 이 파일의 지시사항을 따른다.

| 에이전트 | 호출 명령 | 사용 시점 |
|----------|-----------|-----------|
| Terraform Writer | `/terraform-writer` | 신규 모듈·리소스 작성, 환경 구성 파일 작성, 리팩토링 |
| Terraform Reviewer | `/terraform-reviewer` | 작성된 Terraform 코드 검토 요청 시 |
| AWS Architect | `/aws-architect` | 아키텍처 설계 검토, Well-Architected 리뷰 요청 시 |
| Security Engineer | `/security-engineer` | IAM·네트워크·암호화·EKS 보안 검토 요청 시 |
| Kubernetes Specialist | `/kubernetes-specialist` | Karpenter·add-on·Helm values·K8s 리소스 작업 시 |

### 권장 작업 흐름

```
코드 작성 (terraform-writer)
  → 코드 리뷰 (terraform-reviewer)
  → 보안 검토 (security-engineer)
  → 아키텍처 리뷰 (aws-architect)
```

prd 변경 시 `/review-terraform` Skill이 위 3단계 리뷰를 자동 진행한다.

---

## 프로젝트 컨텍스트

- **폴더 구조 상세**: `@docs/project-structure.md` 참조
- **Git 컨벤션**: `@docs/git-convention.md` 참조
- **Terraform 원칙**: `@docs/terraform-principles.md` 참조
- **모듈 CLAUDE.md 작성 기준**: `@docs/module-claude-template.md` 참조
- **Git 저장소**: https://github.com/hul0810/eks-terraform-practice-with-claude
- **목적**: ECS 경험자가 EKS + Terraform 기술 스택을 실무 수준으로 학습
- **환경**: `develop` / `production` 2개
- **리전**: `ap-northeast-2` (서울)
- **오토스케일링**: Karpenter
- **모니터링**: Prometheus + Grafana (kube-prometheus-stack)
- **상태 관리**: S3 + DynamoDB 원격 백엔드
