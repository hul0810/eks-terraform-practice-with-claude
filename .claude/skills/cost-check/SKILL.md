---
name: cost-check
description: >
  Terraform 코드 변경에 대한 비용 영향을 분석하는 스킬.
  infracost로 배포 전 예상 비용을 계산하고, AWS Billing MCP로 실제 비용 데이터를 조회한다.
  cost-engineer 에이전트가 양쪽 결과를 해석하고 soft gate로 진행 여부를 확인한다.
disable-model-invocation: false
allowed-tools:
  - Agent
  - Bash(infracost*)
  - Bash(git diff*)
---

## 실행 절차

아래 순서를 반드시 지킨다.

### Step 0: 사전 확인

`infracost --version` 명령으로 설치 여부를 확인한다.

설치되지 않은 경우:
```
[안내] infracost가 설치되지 않았습니다.
아래 명령으로 설치 후 다시 실행하세요:

  winget install Infracost.Infracost
  infracost auth login

설치 가이드: https://www.infracost.io/docs/
```
위 메시지를 출력하고 종료한다.

### Step 1: 변경 대상 탐지

`$ARGUMENTS`가 있으면 해당 경로를 대상으로 사용한다.

`$ARGUMENTS`가 없으면 아래 명령으로 변경된 .tf 파일을 탐지한다:
```bash
git diff HEAD --name-only -- "*.tf" "**/*.tf"
```

변경된 파일에서 `project/environments/` 하위 디렉토리만 추출해 중복 제거한다.
예: `project/environments/develop/ap-northeast-2/shared/eks/locals.tf` → `project/environments/develop/ap-northeast-2/shared/eks`

변경된 .tf 파일이 없으면:
```
[안내] 비용 체크 대상 Terraform 파일이 없습니다.
Terraform 파일을 변경한 후 다시 실행하세요.
```
위 메시지를 출력하고 종료한다.

### Step 2: infracost diff 실행

Step 1에서 추출한 각 환경 디렉토리에서 실행한다:
```bash
infracost diff --path <dir> --format json
```

JSON 결과를 수집한다. 오류 발생 시 해당 디렉토리는 건너뛰고 오류 내용을 기록한다.

### Step 3: cost-engineer 에이전트 호출

`cost-engineer` 에이전트를 호출한다. 아래 내용을 전달한다:
- Step 2에서 수집한 infracost JSON 결과
- 분석 대상 환경 디렉토리 목록
- AWS Billing MCP를 통해 실제 최근 30일 비용(`get_cost_and_usage`)과 이상 감지(`get_anomalies`)도 함께 조회 요청

에이전트로부터 비용 분석 리포트와 `COST_STATUS`를 받는다.

### Step 4: Soft gate

리포트를 출력한 후 아래와 같이 진행 여부를 확인한다:

```
계속 진행할까요? (y/N)
```

- **y**: 통과. "비용 확인 완료. 진행합니다."를 출력한다.
- **N 또는 입력 없음**: 작업을 중단한다. COST_STATUS가 ATTENTION 이상이면 최적화 방향을 추가로 안내한다.
