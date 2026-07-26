---
name: review-terraform
description: >
  변경된 Terraform 코드를 terraform-reviewer, security-engineer, aws-architect, cost-engineer 에이전트가 순차 리뷰한다.
  /git-commit 실행 시 production .tf 변경이 있으면 Step 4에서 자동 호출된다. develop 환경에서는 /review-terraform으로 수동 호출한다.
disable-model-invocation: false
allowed-tools:
  - Agent
  - Read
  - Glob
  - Bash(git diff HEAD --name-only*)
  - Bash(infracost*)
---

## 공통 전제 — 근거 기반 검토

네 에이전트 모두 아래를 지킨다 (상세: `docs/terraform-principles.md` → "근거 기반 작업 원칙").

- **주관으로 지적하지 않는다.** "보통 이렇게 한다" 수준의 근거로 지적하지 않는다. 근거를 찾을 수 없으면 확인 항목으로 남긴다.
- **MCP를 먼저 활용한다.** 공식 문서 및 공신력 있는 기술 자료(AWS 공식 블로그 등)를 조회한 근거 위에서 검토 방향을 잡는다.
- **확인분과 추론분을 구분한다.** 지적에 출처를 밝히고, 문서로 확인하지 않은 항목은 "미확인"으로 표기한다. 심각도는 근거 강도에 비례해야 한다.

## 에이전트별 검토 범위

각 에이전트의 역할은 아래와 같이 분리한다. 중복 검토 없이 자신의 영역에만 집중한다.

| 에이전트 | 검토 영역 |
|----------|-----------|
| terraform-reviewer | HCL 코드 품질, 리소스 설계, provider 버전, 베스트 프랙티스 |
| security-engineer | IAM 최소 권한, Security Group 규칙, KMS 암호화, EKS RBAC, 네트워크 보안 |
| aws-architect | Well-Architected 5개 축, 멀티 AZ 설계, 재해복구, 운영성, 서비스 한도 |
| cost-engineer | infracost 예상 비용 delta, Cost Explorer 실제 비용, 비용 함정 진단, 최적화 제안 |

---

## 리뷰 절차

아래 순서를 반드시 지킨다.

### Step 0: 리뷰 대상 파악

1. `$ARGUMENTS`가 있는 경우 → `$ARGUMENTS`를 리뷰 대상 파일 경로로 사용한다.
2. `$ARGUMENTS`가 없는 경우 → 아래 명령으로 커밋되지 않은 .tf 파일 목록을 추출한다:
   ```
   git diff HEAD --name-only -- "*.tf" "**/*.tf"
   ```
   변경된 .tf 파일이 없으면 "리뷰할 변경 사항이 없습니다"를 안내하고 종료한다.

### Step 1: Terraform 코드 리뷰

`terraform-reviewer` 에이전트를 사용하여 리뷰 대상 파일 전체를 검토한다.
에이전트에게 다음을 전달한다:
- 리뷰 대상 파일 목록과 파일 내용
- 검토 범위: HCL 코드 품질, 리소스 설계, provider 버전, 비용, 베스트 프랙티스 (보안·아키텍처 제외)
- 리뷰 완료 후 결과 마지막에 `REVIEW_STATUS: PASSED` 또는 `REVIEW_STATUS: BLOCKED` 출력 요청
  (Critical 또는 Major 이슈 존재 시 BLOCKED)

### Step 2: 보안 검토

`security-engineer` 에이전트를 사용하여 동일 파일을 보안 관점으로 검토한다.
에이전트에게 다음을 전달한다:
- 리뷰 대상 파일 목록과 파일 내용
- 검토 범위: IAM 최소 권한, Security Group 규칙, KMS 암호화, EKS RBAC, 네트워크 보안
- 리뷰 완료 후 결과 마지막에 `REVIEW_STATUS: PASSED` 또는 `REVIEW_STATUS: BLOCKED` 출력 요청
  (High 이상 위험도 보안 이슈 존재 시 BLOCKED)

### Step 3: AWS 아키텍처 리뷰

`aws-architect` 에이전트를 사용하여 동일 파일을 Well-Architected Framework 기준으로 검토한다.
에이전트에게 다음을 전달한다:
- 리뷰 대상 파일 목록과 파일 내용
- 검토 범위: Well-Architected 5개 축, 멀티 AZ 설계, 재해복구, 운영성, 서비스 한도
- 리뷰 완료 후 결과 마지막에 `REVIEW_STATUS: PASSED` 또는 `REVIEW_STATUS: BLOCKED` 출력 요청
  (High 이상 위험도 항목 존재 시 BLOCKED)

### Step 4: 비용 리뷰

`cost-engineer` 에이전트를 사용하여 비용 영향을 분석한다.
에이전트에게 다음을 전달한다:
- 리뷰 대상 환경 디렉토리 목록
- infracost diff 실행 및 예상 비용 변화 분석 요청 (infracost가 없으면 분석 생략 후 메모)
- AWS Billing MCP로 최근 30일 실제 비용(`get_cost_and_usage`) 및 이상 감지(`get_anomalies`) 조회 요청
- 리뷰 완료 후 결과 마지막에 `COST_STATUS: OK`, `COST_STATUS: ATTENTION`, 또는 `COST_STATUS: REVIEW_REQUIRED` 출력 요청

### Step 5: 결과 종합

- **네 리뷰 모두 PASSED/OK**: 완료 보고 후 `/git-commit` Step 5로 진행
- **하나라도 BLOCKED 또는 COST_STATUS: REVIEW_REQUIRED**: 이슈 목록과 수정 방향 안내.
  수정 후 `/review-terraform`을 다시 호출해야 함

### 긴급 우회 (비권장)

사용자가 명시적으로 "리뷰 스킵" 또는 "리뷰 없이 완료"를 요청한 경우에만:
1. 스킵 이유와 파일 목록을 `.claude/.prd-review-skipped.log`에 기록
