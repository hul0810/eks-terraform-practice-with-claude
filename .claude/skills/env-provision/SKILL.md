---
name: env-provision
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(VPC NAT Gateway, EKS 클러스터, eks-addons)를
  올바른 순서로 생성한다. 모든 환경이 GitOps Bridge(modules/eks-addons/2.0.0)를 쓰는 지금은
  Karpenter/ESO의 kubernetes_manifest가 ArgoCD 소관이라 CRD 순환 의존 자체가 없고, monitoring의
  count 에러 원인도 코드 수정으로 해소되어 eks-addons는 단일 apply로 ArgoCD 부트스트랩부터 addon
  IAM까지 한 번에 끝난다 — addon 17개 등록·sync는 전부 자동화돼 있어(devops-manifest의
  automated syncPolicy) 사람이 순서를 정할 필요가 없다. LBC 웹훅 준비 전 다른 addon이 먼저
  reconcile을 시도하는 일시적 경쟁 상태, ExternalDNS cross-account role 신뢰 정책 갱신(필요한
  환경만) 등 반복 실패 패턴은 발생 시 감지해 재시도한다. observability 루트가 있는 환경
  (monitoring)은 클러스터 생성 후 그 루트도 apply해 LGTM S3/IAM/Pod Identity Association을
  (재)생성한다 — Association은 teardown 시 클러스터와 함께 삭제되므로 재provision 시 필수. 3개
  환경 모두 실습용이므로 production도 대상이다.
disable-model-invocation: false
allowed-tools:
  - Bash(terraform *)
  - Bash(aws *)
  - Bash(kubectl *)
  - Read
  - Grep
  - Glob
  - Edit
---

## 사용법

`$ARGUMENTS`로 대상 환경을 받는다: `monitoring` / `develop` / `production`.

```
/env-provision monitoring
/env-provision develop
/env-provision production
```

## 실행 절차

아래 순서를 반드시 지킨다. 각 단계는 이전 단계가 성공해야 진행한다.

### Step 0: 환경 파라미터 결정

`$ARGUMENTS`가 없으면 중단하고 안내한다:

```
[안내] 대상 환경을 지정하세요: /env-provision monitoring | develop | production
```

`monitoring` | `develop` | `production` 외 값이면 오류 출력 후 종료.

`production`인 경우, 실행 전 아래를 출력하고 확인을 받는다 (다른 환경보다 리소스 규모가 크고
과금 영향이 크므로):

```
[확인] production 환경에 리소스를 생성합니다. 계속할까요? (y/N)
```

`y`가 아니면 중단한다.

> **develop/production 선행조건 — monitoring(Hub)이 먼저 provision되어 있어야 한다
> (2026-07-23 도입)**: develop/production의 `eks-addons`가 Step 3에서 SSM에 자기
> registry payload를 publish하려면(`gitops-bridge-registry.tf`), monitoring의
> `eks-addons`가 만든 `<monitoring-cluster-name>-gitops-bridge-registry-writer-<이 환경의
> account_id>` IAM Role을 assume해야 한다. monitoring이 아직 없거나(최초 provision) 최근에
> teardown된 상태면 이 Role이 없어 publish가 provider 단계에서부터 막힌다.
>
> **이 의존은 `eks-addons` 레이어에만 적용된다** — 여러 환경을 한 요청으로 provision할 때
> VPC·EKS까지 직렬화하지 말 것. 겹쳐 실행하는 정확한 순서는 위 "시간 단축이 최우선" 절을
> 따른다(develop EKS는 monitoring **VPC**의 NAT만 필요하므로 monitoring EKS와 동시에 만든다).
> `develop`/`production` 단독 호출이어도 Step 3 진입 전 아래로 선행조건을 확인한다:
>
> ```bash
> aws iam get-role --profile terraform-monitoring \
>   --role-name "<monitoring cluster_name>-gitops-bridge-registry-writer-<이 환경의 account_id>" 2>&1
> ```
>
> (`<monitoring cluster_name>`은 `monitoring/environments/ap-northeast-2/shared/eks/locals.tf`의
> `cluster_name`, 이 환경의 `account_id`는 이 root `providers.tf`의 `profile`로 `aws sts
> get-caller-identity`.) `NoSuchEntity`면 monitoring이 아직 이 환경을 신뢰 계정으로
> 등록하지 않은 것이니, 진행 전 monitoring을 먼저 `/env-provision monitoring`하라고
> 안내하고 중단한다.
>
> **eks-addons가 GitOps Bridge(2.0.0)인 spoke 환경은 registry publish + Hub 재apply
> 없이는 addon Helm이 전혀 설치되지 않는다**: Terraform은 IAM만 만들고 Helm release는
> ArgoCD가 만들기 때문에, 이 단계를 빠뜨리면 LBC/Karpenter/ExternalDNS/ExternalSecrets
> 파드가 하나도 없는 클러스터로 끝난다. 이 작업 자체는 Step 3의 정식 절차로 승격되어
> 있다 — 아래 3-B-1.5 참조. `production 자신의 eks-addons에 gitops-bridge-registry.tf가
> 없으면` develop의 동일 파일(`gitops-bridge-registry.tf`/`locals.tf`의
> `gitops_bridge_registry_payload`/`providers.tf`의 `aws.gitops_bridge_registry`)을
> 그대로 본떠 먼저 만들어야 한다.

> **참고**: `production`은 `.claude/hooks/block-production-apply.sh`(PreToolUse 훅)가
> `environments/production` 경로의 모든 `terraform apply`를 무조건 차단한다 (CLAUDE.md
> "Production 배포 정책" 참조). 이 스킬은 production에서도 환경 인식·root 디렉토리 판별·
> 각 단계 사전 확인까지는 동일하게 진행하지만, 실제 `terraform apply` 실행 시점에는 훅이
> 차단하고 종료 코드 2를 반환한다. 이 경우 훅 출력 메시지를 그대로 사용자에게 보여주고
> 중단한다 — 재시도하지 않는다. 사용자가 터미널에서 직접 `terraform apply`를 실행한 뒤
> 다음 Step으로 이어서 진행해달라고 안내한다.

**환경별 root 디렉토리** (하드코딩하지 않고 아래 매핑만 사용, 세부값은 이후 각 단계에서 파일을 직접 읽어 확인한다):

| 환경 | root |
|------|------|
| monitoring | `monitoring/environments/ap-northeast-2/shared` |
| develop | `project/environments/develop/ap-northeast-2/shared` |
| production | `project/environments/production/ap-northeast-2/shared` |

이후 단계의 `{root}`는 이 값을 가리킨다.

### 공통 처리: [주의] 이 문서에 `＄0`~`＄9`를 쓰지 않는다 — 슬래시 명령 인자로 치환된다

**이 SKILL.md가 로드될 때 본문의 `＄0`~`＄9`가 슬래시 명령의 위치 인자로 그대로 치환된다.**
`＄0`은 첫 번째 인자, `＄1`은 두 번째 인자로 바뀌며, 인자 개수만큼만 치환되므로 **인자를
몇 개 주느냐에 따라 깨지는 위치가 달라진다** — 파일 원문은 멀쩡한데 로드된 내용만 틀리는
형태라 눈치채기 어렵다. **이 섹션의 예시는 전각 `＄`로 적었다** — 반각으로 적으면 이
설명문 자체가 치환돼 앞뒤가 같은 줄이 되어버린다:

```bash
# 파일 원문
out=$(... | awk '{print ＄1, ＄2, ＄3}')
# /env-provision develop monitoring 으로 로드했을 때 실제로 보이는 것
out=$(... | awk '{print monitoring, ＄2, ＄3}')
```

따라서 이 문서의 셸·awk 스니펫에서는 위치 필드 참조를 쓰지 않는다. 대안:

| 하려던 것 | `$N` 대신 |
|---|---|
| `kubectl` 출력에서 열 뽑기 | `-o jsonpath`로 필요한 값만 출력하고 `grep`/`cut`으로 처리 |
| 특정 열 값으로 필터 | `grep ' Synced Healthy$'`처럼 **줄 전체 패턴**으로 매칭 |
| ini 파일에서 키 값 추출 | `sed -n '/^\[블록\]/,/^\[/p' | sed -n 's/^키[[:space:]]*=[[:space:]]*//p'` |

`$NF`·`${i}`·`$((...))`·`$VAR`는 치환 대상이 아니므로 그대로 써도 된다 — **숫자 하나짜리
`＄0`~`＄9`만** 문제다.

> **WHY (2026-08-10 발견)**: 원래 SSO 알림 루프의 `awk '＄0==p{...}'`가 이 결함을 갖고
> 있었는데 로드된 텍스트를 자세히 보지 않아 오래 남아 있었고, 2026-08-09에 sync 안정화
> 루프를 고치면서 `＄1`을 두 군데 더 추가했다. 실행에는 영향이 없었다(명령은 매번 직접
> 작성했다) — 다만 **이 문서만 보고 따라가는 세션은 깨진 awk를 그대로 쓰게 된다.**
> 4곳 전부 위 대안으로 교체했다.

### 공통 처리: 시간 단축이 최우선 — 의존성이 없는 것은 무조건 병렬로 돌린다

이 스킬의 1순위 목표는 **환경이 사용 가능해질 때까지의 벽시계 시간을 줄이는 것**이다.
아래 의존성 표 밖의 조합은 전부 동시에 실행한다. 각 Step을 순서대로 "완료 후 다음"으로
직렬 처리하지 말 것 — Step 번호는 의존 관계가 아니라 서술 순서일 뿐이다.

**실제 의존성은 이것뿐이다** (2026-08-01 monitoring+develop 동시 provision에서 실측):

| 작업 | 진짜 선행 조건 | 흔한 오해 |
|------|---------------|-----------|
| 각 환경 EKS | 자기 VPC 서브넷(이미 존재) | VPC apply 완료를 기다릴 필요 없음 |
| **develop/production EKS** | **monitoring VPC의 NAT Gateway** (`data.aws_nat_gateway.monitoring`) | ~~monitoring 전체 완료~~ — monitoring **EKS·addons와 무관** |
| 각 환경 eks-addons | 자기 EKS 클러스터 | — |
| **spoke eks-addons** | **monitoring eks-addons `apply` 완료**(registry-writer Role) | ~~monitoring addon sync 완료~~ — sync는 무관 |
| observability | 자기 EKS 클러스터 | ~~eks-addons 완료~~ — 별도 state라 무관 |
| Hub 재apply(3-B-1.5) | spoke의 SSM registry publish | — |
| **Step 4 cross-account 신뢰정책** | **자기 환경 eks-addons `apply` 완료** | ~~아무 때나 병렬 가능~~ — 그 root가 이 환경의 eks-addons remote state output(`external_dns_role_arn`)을 읽는다 |

**`monitoring develop`처럼 여러 환경을 한 번에 받으면 아래 순서로 겹쳐 실행한다:**

1. monitoring VPC apply 시작 → **완료 대기**(~1.5분, NAT 생성이 짧다)
2. **monitoring EKS + develop VPC + develop EKS 3개를 동시 시작** — EKS 생성이 ~12분으로
   가장 길므로 두 클러스터를 겹치는 것이 이 스킬 최대의 단축 포인트다
3. monitoring EKS 완료 → kubeconfig → **monitoring eks-addons + observability 동시 시작**
4. monitoring eks-addons **apply가 끝나는 즉시** develop eks-addons 시작
   (monitoring addon sync를 기다리지 않는다) — 동시에 monitoring addon sync 폴링,
   monitoring의 cross-account 신뢰 정책 갱신(Step 4)도 이 구간에 함께 처리한다.
   **단 Step 4는 "그 환경의 eks-addons apply가 끝난 뒤"여야 한다**(위 의존성 표 마지막 행)
5. develop eks-addons 완료 → Hub 재apply → 전체 sync 확인

> **WHY (2026-08-01 실측)**: 이전에는 "monitoring을 완전히 끝내고 develop"으로 직렬
> 처리해 develop EKS 생성 ~12분과 monitoring addon sync 대기 ~15분이 통째로 낭비됐다.
> Step 0의 "monitoring을 먼저 끝내고"라는 문구는 **spoke eks-addons가 Hub의
> registry-writer Role을 필요로 한다**는 뜻이지, 환경 전체를 직렬화하라는 뜻이 아니다.
> VPC·EKS 레이어에는 그 의존이 전혀 없다.

### 공통 처리: AWS SSO 토큰 만료 감지 및 반복 Slack 알림

이 스킬이 실행하는 어떤 `terraform apply`/`plan` 출력에서든 아래 패턴이 보이면 SSO 세션이
만료됐을 수 있다:

| 패턴 | 판정 |
|---|---|
| `refresh cached SSO token failed` | **SSO 만료 확정** — 바로 아래 알림 루프 |
| `InvalidGrantException` | **SSO 만료 확정** — 바로 아래 알림 루프 |
| `No valid credential sources found` | **단독으로는 확정 아님** — 아래 확인 후 판단 |

**[필수] `No valid credential sources found`만 있고 위 두 패턴이 없으면, 알림 루프를 띄우기
전에 로그 원문에서 아래를 먼저 확인한다** — 이 문구는 네트워크 실패에서도 똑같이 나온다:

```bash
grep -A8 "^Error" "$RUN_DIR/<실패한 단계>.log" | head -30
```

`wsarecv`, `connection was forcibly closed`, `exceeded maximum number of attempts`,
`i/o timeout`, `no such host` 중 하나라도 있으면 **네트워크 오류이므로 재로그인이 아니라
같은 명령을 1회 재시도한다**(`[실패]` 접두사로 timing 기록). 재시도도 같은 이유로 실패하면
그때 사용자에게 보고한다.

> **WHY (2026-08-09 실측)**: develop provision의 Hub 재apply가
> `No valid credential sources found`로 실패해 SSO 만료로 판단하고 알림 루프를 띄운 뒤
> 사용자에게 재로그인을 요청했다. 실제 원인은 네트워크였다 —
> `GetRoleCredentials, exceeded maximum number of attempts, 3 ... wsarecv: An existing
> connection was forcibly closed by the remote host.` SSO 토큰은 유효했고(알림 루프가
> 0회차에 즉시 `SSO_RESOLVED`) 재로그인 없이 그대로 재시도해 19초에 성공했다. 세 패턴을
> 동급으로 나열한 것이 오진의 직접 원인이다. 같은 세션에서 `kubectl get nodes`도 한 번
> `wsarecv`로 끊겼다 — 이 환경에서 순간 단절은 드물지 않다.

**SSO 만료로 확정되면 아래 백그라운드 루프를 시작한다** — LLM 턴을 소비하지 않는 순수 쉘 루프라
10초 간격 반복이 부담 없다 (`run_in_background: true`, `timeout: 600000`):

```bash
PROFILE="<해당 root/서브디렉토리 providers.tf의 profile>"
ENV_NAME="<환경>"
WEBHOOK="$SLACK_WEBHOOK_URL"
CMD_HINT="aws sso login --profile $PROFILE"
SSO_SESSION=$(sed -n "/^\[profile ${PROFILE}\]/,/^\[/p" ~/.aws/config \
  | sed -n 's/^[[:space:]]*sso_session[[:space:]]*=[[:space:]]*//p' | head -1)
CACHE_FILE="$HOME/.aws/sso/cache/$(printf '%s' "$SSO_SESSION" | sha1sum | cut -d' ' -f1).json"
i=0
while true; do
  EXPIRES_AT=$(jq -r '.expiresAt // empty' "$CACHE_FILE" 2>/dev/null)
  EXPIRES_EPOCH=$(date -u -d "$EXPIRES_AT" +%s 2>/dev/null)
  NOW_EPOCH=$(date -u +%s)
  if [ -n "$EXPIRES_EPOCH" ] && [ "$EXPIRES_EPOCH" -gt "$NOW_EPOCH" ]; then
    echo "SSO_RESOLVED (반복 ${i}회 후 감지)"; break
  fi
  if [ -n "$WEBHOOK" ]; then
    msg=$(printf '<!channel> ⚠️ SSO_LOGIN_REQUIRED — *[%s] provision 중단*\n실행: `%s`\n대기 중: <현재 막힌 단계>\n반복 %s회' "$ENV_NAME" "$CMD_HINT" "$i")
    payload=$(jq -nc --arg text "$msg" '{text:$text}')
    printf '%s' "$payload" | curl -s -X POST -H 'Content-type: application/json' --data-binary @- --max-time 5 "$WEBHOOK" >/dev/null 2>&1
  fi
  i=$((i+1)); sleep 10
done
```

`SSO_RESOLVED`가 출력되면 실패했던 명령을 그대로 재실행한다. **재로그인 직후 중간에 다른
`aws` 명령을 끼워넣지 않는다** — SSO OIDC refresh token은 1회용이라 그 호출이 terraform의
인증 갱신과 경쟁해 다시 실패시킨다(teardown 스킬 동일 섹션의 WHY 참조).

대기 시간은 `[대기] SSO 재로그인` 항목으로 timing.log에 분리 기록하고, 실패한 apply 자체의
소요는 `[실패]` 접두사로 구분해 정상 실행과 섞이지 않게 한다.

> **WHY (2026-08-03)**: 이 루프는 원래 teardown에만 있었다. 근거를 "provision은 실패해도
> 리소스가 새로 생기지 않을 뿐이라 급하지 않다"고 적었는데, **비용만 보고 사용자가 대기
> 상태를 인지하지 못해 낭비되는 시간을 계산에 넣지 않은 판단 오류**였다. 실제로 2026-08-03
> monitoring provision에서 VPC·EKS apply가 동시에 SSO 만료로 죽었고, 사용자가 지적하기
> 전까지 아무 알림 없이 멈춰 있었다. 알림이 곧 재개 시점을 결정하므로 두 스킬 모두에
> 필요하다.

### 공통 처리: `terraform apply`/`destroy` 출력을 파이프로 볼 때는 반드시 `pipefail`

이 스킬의 모든 `terraform apply`/`destroy` 명령을 실제로 실행할 때(백그라운드 실행 포함)
출력이 길어 `| tail -N`으로 줄여서 보는 경우가 많다. **`pipefail` 없이 파이프로 연결하면
파이프라인 전체의 종료 코드가 마지막 명령(`tail`)의 종료 코드가 되어, `terraform`이 실제로
실패해도 `tail`은 항상 0을 반환한다** — 그 결과 백그라운드 작업 완료 알림에 "completed
(exit code 0)"로 잘못 보고되어 실패가 감춰진다. 반드시 아래 중 하나를 지킨다:

```bash
set -o pipefail && terraform apply -auto-approve -no-color 2>&1 | tail -60
```

또는 파이프 없이 전체 출력을 받은 뒤 `Apply complete!`/`Error` 문자열로 직접 성공 여부를
판단한다. 어느 쪽이든, **알림에 찍힌 종료 코드만 믿지 말고 출력 내용(마지막 줄이
`Apply complete!`/`Destroy complete!`인지, 아니면 `Error`가 있는지)을 반드시 눈으로
확인한 뒤에만 다음 Step으로 진행한다.**

> **WHY (2026-07-16 확인)**: monitoring provision 중 VPC와 EKS apply를 SSO 만료 시점에
> 동시에 실행했다. EKS apply는 실패 직후 출력을 직접 확인해 SSO 재로그인 절차로 넘어갔지만,
> VPC apply는 `| tail -30`으로 실행한 뒤 백그라운드 알림의 "completed (exit code 0)"만
> 보고 정상 종료로 오판했다 — 실제로는 VPC apply도 같은 SSO 만료로 실패해 NAT Gateway가
> 전혀 생성되지 않은 상태였다. 사용자가 "NGW 생성 안 되어있는데 확인해라"라고 지적하고서야
> `.output` 파일을 직접 열어 `No valid credential sources found` 에러를 발견했다. 이후
> 로그인 후 재시도로 정상 생성됨을 확인했다.

### 공통 처리: 실행 로그 위치와 소요 시간 측정

**로그는 저장소 루트의 `temp/log/`에 쓰고, 실행 5회분만 유지한다.** `temp/`는
`.gitignore`에 등록돼 있어 커밋되지 않는다(`.gitignore:43`). Step 0 진입 직후 아래를
1회 실행해 이번 실행 전용 디렉토리를 만든다:

```bash
LOG_ROOT="<저장소 루트>/temp/log"
RUN_DIR="$LOG_ROOT/provision-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
# 최신 5개만 남기고 오래된 실행 디렉토리 삭제
ls -1dt "$LOG_ROOT"/provision-* 2>/dev/null | tail -n +6 | xargs -r -d '\n' rm -rf
echo "RUN_DIR=$RUN_DIR"
```

**[주의] `xargs`에 `-d '\n'`이 반드시 있어야 한다.** 이 저장소의 경로에는 공백이 들어있어
(`바탕 화면`, `개인 프로젝트`, `eks 프로젝트`), 기본 구분자를 쓰면 xargs가 경로 하나를
여러 조각으로 쪼갠다 — `rm -rf`가 존재하지 않는 조각들을 지우려다 `-f` 때문에 조용히
성공하고, **로테이션이 아무 일도 하지 않은 채 통과한다**(2026-08-01 실측: 7개 중 0개 삭제).

이후 이 스킬의 모든 `terraform` 출력은 `$RUN_DIR/<단계이름>.log`로 리다이렉트한다
(예: `> "$RUN_DIR/mon-eks-apply.log" 2>&1`). `RUN_DIR` 값은 세션 중 계속 재사용해야
하므로 **첫 실행 결과를 기억해두고 이후 명령에 문자열로 직접 넣는다** — Bash 도구는
호출 간 쉘 변수를 유지하지 않는다.

**소요 시간은 단계별로 측정해 `$RUN_DIR/timing.log`에 누적한다:**

```bash
s=$(date +%s); <실제 명령>; e=$(date +%s); \
  printf '%-34s %5ds\n' "<단계이름>" "$((e-s))" | tee -a "$RUN_DIR/timing.log"
```

**접두사 규칙** — 같은 단계가 여러 줄로 남을 때 성격을 구분한다:

| 접두사 | 의미 | 합계 포함 |
|---|---|---|
| (없음) | 정상 실행 | 포함 |
| `[대기]` | 사람 대기(SSO 재로그인 등) — 절차 최적화로 줄일 수 없음 | **제외** |
| `[실패]` | 실패한 시도(SSO 만료 등)로 버린 시간 | 포함 (실제 소요이므로) |

`[대기]`를 분리하지 않으면 자동화 구간 성능 판단이 흐려지고, `[실패]`를 정상 실행과 같은
이름으로 남기면 같은 단계가 중복돼 로그를 읽을 수 없다.

Step 5 완료 메시지에 총 소요 시간과 단계별 내역을 함께 출력한다:

```bash
cat "$RUN_DIR/timing.log"
printf '%-34s %5ds\n' "총 소요(자동화 구간 합)" \
  "$(awk '!/^\[대기\]/{gsub(/s$/,"",$NF); t+=$NF} END{print t+0}' "$RUN_DIR/timing.log")"
```

> **WHY (2026-08-01)**: 이 스킬은 "시간 단축이 최우선"을 표방하는데, 정작 어느 단계가
> 얼마를 잡아먹었는지 측정하지 않아 병렬화 효과를 매번 체감으로만 판단했다. 측정값이
> 남으면 다음 실행에서 개선 효과를 숫자로 검증할 수 있다. teardown 쪽 동일 섹션과
> 디렉토리 접두사(`provision-`/`teardown-`)만 다르고 규칙은 같다.

### Step 1: VPC NAT Gateway 활성화 — EKS와 병렬 시작

`{root}/vpc/locals.tf`를 Read하여 `enable_nat_gateway` 현재 값을 확인한다.

- 이미 `true`: "[안내] NAT Gateway가 이미 활성화되어 있습니다." 출력 후 Step 2로.
- `false`: Edit로 `true`로 변경 후 아래를 **백그라운드로 실행**하고, 완료를 기다리지 않고
  바로 Step 2로 진행한다:

```bash
cd {root}/vpc && terraform apply -auto-approve
```

> **WHY 병렬 처리 (2026-07-04 확인)**: EKS 모듈이 remote state로 참조하는 subnet_id 등은
> NAT Gateway 토글과 무관하게 이미 존재하는 서브넷이라 이 apply 완료를 기다릴 필요가 없다.
> EKS 컨트롤 플레인 생성(~10~15분)이 NAT Gateway 생성(~1~2분)보다 훨씬 오래 걸리므로,
> 노드가 실제로 아웃바운드가 필요해지는 시점(노드 그룹 부트스트랩)에는 NAT Gateway가 이미
> 준비되어 있다. 순차 실행 대비 대기 시간을 크게 줄인다.

이 apply가 실패하면 Step 2 진행 상황과 무관하게 즉시 사용자에게 보고한다.

### Step 2: EKS 클러스터 생성

```bash
cd {root}/eks && terraform apply -auto-approve
```

**Step 1의 VPC apply가 이 시점에 아직 끝나지 않았다면 여기서 완료를 기다린 뒤 결과를
확인한다** (실패 시 중단, 이후 단계 진행 금지 — Step 3 eks-addons이 실제로 아웃바운드를
쓰기 전까지는 여유가 있으므로 지금 확인해도 순차 실행 대비 손해가 없다).

완료 후 **반드시** kubeconfig를 갱신한다:

1. `{root}/eks/locals.tf`(또는 `outputs.tf`)에서 `cluster_name` 값을 Grep으로 확인
2. `{root}/eks/providers.tf`에서 `profile` 값을 Grep으로 확인
3. 아래 실행:

```bash
aws eks update-kubeconfig --name <cluster_name> --region ap-northeast-2 --profile <profile> --alias <cluster_name>
```

> **WHY**: 클러스터를 destroy 후 재생성하면 API 엔드포인트(클러스터 내부 ID)가 바뀐다.
> 이 갱신 없이는 이후 모든 `kubectl` 명령이 옛 엔드포인트를 찾다가 `dial tcp: lookup ... no such host`로 실패한다.

`kubectl get nodes`로 시스템 노드가 `Ready`가 될 때까지 대기한다 (최대 5분 polling).

### Step 3: eks-addons 생성

**먼저 이 환경이 GitOps Bridge 구조인지 확인한다** (2026-07-21 기준 monitoring/develop이
`2.0.0`, production은 코드만 `2.0.0`(apply 전) — `1.0.0`을 실제로 참조하는 환경은 이제 없다.
아래 grep은 향후 신규 환경이 다시 레거시로 시작할 가능성을 대비해 하드코딩 대신 동적으로 확인한다):

```bash
grep "source" {root}/eks-addons/main.tf | grep "modules/eks-addons"
```

`modules/eks-addons/1.0.0`이면 **3-A(레거시)**를, `2.0.0` 이상이면 **3-B(GitOps Bridge)**를 따른다.

---

#### 3-A. 레거시 절차 (`modules/eks-addons/1.0.0` — 예: develop/production)

**3-A-1. 선행 CRD 설치 — 항상 먼저 실행 (전체 apply를 바로 시도하지 않는다)**

Step 2에서 클러스터를 새로 만든 직후에는 Karpenter/external-secrets CRD가 클러스터에
없어, 이 root가 직접 선언하는 Karpenter NodeClass/NodePool·ESO ClusterSecretStore/
ExternalSecret 등 `kubernetes_manifest` 리소스의 plan 자체가 **항상** 실패한다
(`hashicorp/kubernetes` provider가 plan 단계에서 클러스터 API로 CRD 스키마를 직접 조회하기
때문에 `depends_on`으로는 막을 수 없다). 이 실패가 예정돼 있으므로, 전체 apply를 먼저
시도해 실패를 확인하는 절차를 생략하고 module 전체를 target으로 먼저 적용한다:

```bash
cd {root}/eks-addons && terraform apply -auto-approve -target=module.eks_addons
```

target 범위는 karpenter/external_secrets helm_release 2개만이 아니라 `module.eks_addons`
전체로 넓혀, LBC/ArgoCD/external-dns/argo-rollouts 등 CRD와 무관한 나머지 애드온도 이
1단계에서 함께 설치되게 한다 — 단, ArgoCD의 Ingress는 이 module 안에 포함되므로
3-A-3의 LBC 웹훅 경쟁은 이 1단계에서도 여전히 발생할 수 있다(아래 참고).

> **참고(2026-07-22)**: 2026-07-22 기준 이 3-A 절차 자체가 참조하는 `modules/eks-addons/1.0.0`을
> 실제로 쓰는 환경이 없다(monitoring/develop/production 전부 2.0.0 — 아래 3-B). 게다가
> 1.0.0 모듈 자신도 Karpenter NodeClass/NodePool·ESO ClusterSecretStore/ExternalSecret용
> `kubernetes_manifest`를 갖고 있지 않다(그 모듈이 갖는 `kubernetes_manifest`는
> OTel spoke collector 전용뿐 — `modules/eks-addons/1.0.0/main.tf` 확인). 즉 이 문단이
> 설명하는 시나리오는 "환경 root가 그런 리소스를 직접 선언하는 경우"를 가정한 일반
> 절차이고, 지금 이 리포지토리의 어떤 파일에도 그 형태로 매칭되는 코드가 없다 — 신규
> 환경이 1.0.0을 참조하며 그런 리소스를 직접 추가하는 극히 예외적 상황이 아니면 3-A는
> 실질적으로 죽은 절차다. 대부분의 경우 아래 3-B를 따르면 된다.

**3-A-2. 전체 apply**

```bash
cd {root}/eks-addons && terraform apply -auto-approve
```

**3-A-3. LBC 웹훅 경쟁 상태 감지 시 (3-A-1, 3-A-2 어느 단계에서 발생해도 동일하게 처리)**

아래 패턴이 있으면 LBC와 ArgoCD(Ingress 포함)가 병렬 생성되며 LBC 웹훅이 아직 뜨기 전에
ArgoCD Ingress 생성이 시도된 것이다 (일시적):

- `no endpoints available for service "aws-load-balancer-webhook-service"`

`kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`로
LBC 파드가 `Running`인지 확인 후 **직전에 실패한 단계(3-A-1 또는 3-A-2)를 그대로 재실행**한다
(최대 2회).

**3-A-4. external-secrets 웹훅 미기동 감지 시**

- `no endpoints available for service "external-secrets-webhook"`

`kubectl get pods -n external-secrets`로 3개 파드(`external-secrets`,
`external-secrets-cert-controller`, `external-secrets-webhook`)가 모두 `Running`인지 확인
(최대 3분 polling) 후 **3-A-2의 전체 apply를 재실행**한다.

**3-A-5. 그럼에도 CRD 순환 의존 에러가 나타나는 경우**:

- `no matches for kind "EC2NodeClass" in group "karpenter.k8s.aws"`
- `no matches for kind "ClusterSecretStore" in group "external-secrets.io"`

3-A-1을 그대로 재실행해 CRD 설치를 확인한 뒤 (`kubectl get crd | grep -E "karpenter|external-secrets"`),
3-A-2를 재실행한다.

**3-A-6.** 위 패턴에 해당하지 않는 다른 에러는 재시도하지 말고 사용자에게 보고 후 중단한다.

---

#### 3-B. GitOps Bridge 절차 (`modules/eks-addons/2.0.0` 이상 — 2026-07-21 기준 monitoring/develop,
production은 코드만)

**핵심 차이**: Terraform은 이제 ArgoCD 자신과, GitOps로 이관된 addon(LBC/Karpenter/
ExternalDNS/ExternalSecrets 등, 이관 목록은 `TODO_LIST.md` Phase 6-4/6-5 참조)의 **IAM/AWS
리소스만** 만든다. addon의 실제 Helm release(파드)는 ArgoCD가 devops-manifest를 sync해야
생긴다.

> **갱신(2026-07-21)**: ESO의 ClusterSecretStore/ExternalSecret, Karpenter의
> EC2NodeClass/NodePool은 monitoring(Phase 6-4)에 이어 develop(Phase 6-5)도 완전히
> ArgoCD로 이관을 마쳐, 2026-07-21 기준 어떤 환경의 eks-addons root에도 이 CRD 의존
> `kubernetes_manifest` 리소스가 남아있지 않다(둘 다 `terraform state list`에 Karpenter
> NodeClass/NodePool 항목이 없다). 즉 아래 3-B-2의 sync **순서**(LBC 먼저 등)는 여전히
> Helm chart 간 webhook 의존성 때문에 필요하지만, "CRD가 없어 `terraform plan` 자체가
> 실패한다"는 문제는 더 이상 발생하지 않는다 — 이 절만 놓고 보면 3-A의 단순한 1회 apply와
> 큰 차이가 없어졌다. 다만 `enable_otel_spoke_collector=true`로 OTel spoke collector를
> 켜는 환경은 `kubernetes_manifest.otel_spoke_node`/`otel_spoke_singleton`이 여전히
> Terraform 소관이라 그 경우엔 CRD(OTel Operator) 선설치가 여전히 필요하다.

**3-B-1. 전체 apply — 단일 apply로 충분 (2026-07-24 갱신, `-target` 선행 단계 폐지)**

과거엔 `-target=module.eks_addons`로 ArgoCD 부트스트랩 + addon IAM만 먼저 적용한 뒤,
바깥의 registry publish를 별도 apply로 나눴다. 이 단계 분리가 필요했던 이유는 두 가지였고
둘 다 이제 해소됐다:

1. **레거시 CRD 의존 plan 실패**(3-A 유산) — 위 2026-07-21 갱신에서 이미 해소됨(CRD 의존
   `kubernetes_manifest`가 전부 ArgoCD 관리로 이관).
2. **monitoring 전용 `Invalid count argument`**: Hub 자신의 cluster Secret을 만드는
   벤더 모듈(`gitops-bridge-dev/gitops-bridge/helm`)의 `kubernetes_secret_v1.cluster`가
   `count = var.create && (var.cluster != null) ? 1 : 0`인데, `locals.tf`의
   `gitops_bridge_hub_cluster.metadata.argocd_image_updater_role_arn`이 같은 apply에서
   새로 생성되는 `aws_iam_role.argocd_image_updater.arn`(리소스 속성 참조)을 담고 있어
   fresh apply 시점엔 이 값이 미지값이었다 — `count`가 참조하는 객체 안에 미지값이 하나만
   있어도 Terraform은 `!= null` 판정과 무관하게 객체 전체를 미지로 취급해 plan을 실패시킨다.
   `locals.tf`에서 이 참조를 `"arn:aws:iam::${data.aws_caller_identity.current.account_id}
   :role/${local.cluster_name}-argocd-image-updater-irsa"`(계정 ID + 결정론적 Role
   이름 문자열 조합)로 바꿔 리소스 속성 참조 자체를 제거했다(2026-07-24 — `-replace`로
   해당 Role을 강제 재생성해 미지값 상태를 재현하고도 plan/apply가 에러 없이 통과함을
   검증 완료).
3. **develop/production은 애초에 이 문제가 없었다**: registry payload
   (`gitops-bridge-registry.tf`)가 참조하는 `module.eks_addons.gitops_bridge_addon_metadata`는
   `count`/`for_each`를 게이팅하지 않는 평범한 값 참조라, Terraform의 의존성 그래프가
   `module.eks_addons`를 먼저 적용한 뒤 알아서 처리한다 — `-target` 없이도 원래 문제가
   없었다(2026-07-24 develop provision에서 실측: `-target` 이후 이어붙인 전체 apply가
   정확히 나머지 리소스(registry 관련)만 추가하는 것으로 그쳤다).

이제 모든 환경에서 아래 apply 한 번으로 ArgoCD 부트스트랩·addon IAM·(spoke라면 registry
publish까지) 전부 끝난다:

```bash
cd {root}/eks-addons && terraform apply -auto-approve
```

이 시점에 ArgoCD 자체(Helm)와 LBC/Karpenter/ExternalDNS/ExternalSecrets의 IAM Role/Policy,
Karpenter의 SQS 인터럽션 큐·EventBridge Rule, `argocd-github-app-repo-creds` Secret(SSM에서
직접 읽어 Terraform이 만듦 — ESO 비의존)까지 전부 준비된다. ArgoCD는 이 시점부터 자기
저장소(devops-manifest)를 정상적으로 sync할 수 있다.

**3-B-1.5. Hub 재apply — spoke(develop/production) 환경은 여전히 필수**

이 root(`{root}/eks-addons`)에 `gitops-bridge-registry.tf`가 있는 환경(현재 develop/
production — monitoring은 Hub 자신이라 해당 없음)은 3-B-1만으로 끝나지 않는다. 3-B-1의
apply로 SSM에 이 클러스터의 registry payload가 publish됐지만, Hub(monitoring)는 아직
이 클러스터를 spoke로 discovery하지 못한 상태다 — addon Application 자체가 생성되지
않는다. **이건 위에서 없앤 `-target` 문제와는 무관한, publish 시점과 Hub가 discovery하는
시점이 원래 다른 두 단계 구조라 여전히 필요하다** — Hub의 `data.aws_ssm_parameter`/
`for_each`가 plan 시점에 SSM을 다시 읽어야 새 spoke를 인식하므로, **반드시 Hub(monitoring)
쪽 eks-addons를 한 번 더 apply**한다:

```bash
cd monitoring/environments/ap-northeast-2/shared/eks-addons && terraform apply -auto-approve
```

plan에 `module.gitops_bridge_spoke["<cluster_name>"].kubernetes_secret_v1.cluster[0]`가
`will be created`로 나오면 정상이다(적용 후 `kubectl get secret <cluster_name> -n argocd
--context <monitoring-cluster-context>`로 확인 가능). 이 Secret이 생성되는 순간부터
3-B-2의 자동 등록이 실제로 시작된다 — 이 Secret 없이는 어떤 `-spoke` ApplicationSet도
이 클러스터용 Application을 만들지 않는다.

> **WHY (2026-07-23, dev/production provision 중 실제로 매번 수동 처리)**: 이 스킬은
> 원래 이 단계 없이 3-B-1 → 3-B-2로 바로 넘어가는 것처럼 쓰여 있었다. 실제로 develop과
> production을 provision할 때 둘 다 이 단계를 빠뜨리면 addon Application이 전혀
> 생성되지 않아(Hub가 그 spoke의 존재 자체를 모름) 매번 그때그때 판단해 수동으로
> 끼워넣었다 — 정식 Step으로 없으면 다음에 이 스킬만 보고 따라가는 세션이 똑같이
> 빠뜨릴 위험이 있어 절차로 승격한다.

**3-B-1.7. [필수·선제] LBC 파드가 뜨는 즉시 webhook caBundle을 patch한다 — 증상을 기다리지 않는다**

**클러스터를 새로 만든 provision에서는 caBundle 불일치가 사실상 항상 발생한다**(원인은
아래 3-B-3-2 참조 — 차트에 구운 정적 caBundle vs 파드가 매 기동마다 새로 만드는 인증서).
그런데 이 문제는 **Ingress가 ALB를 못 받는 형태로만 드러나서**, Step 5 검증까지 가서야
발견하면 그때까지의 시간이 통째로 낭비된다. 조치 자체는 십수 초로 끝나므로 **증상을
기다리지 말고 LBC 파드가 Running이 되는 즉시 무조건 patch한다** — 이미 일치하는 경우에도
같은 값을 덮어쓰는 것뿐이라 부작용이 없다(멱등).

**[중요] 한 번 patch하고 끝내면 안 된다 — 반드시 "patch → 검증 → 불일치면 재patch" 루프로
돌린다.** 아래 명령은 LBC 기동 대기에 수 분이 걸려 Bash 도구 기본 타임아웃(2분)을 넘기므로
**반드시 `run_in_background: true`로 실행**한다:

```bash
# 1) LBC 파드 Running 대기 (최대 10분)
for i in $(seq 1 60); do
  kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
    --no-headers 2>/dev/null | grep -q "Running" && break
  sleep 10
done

# 2) patch → 검증 → 재시도 (최대 10회)
for attempt in $(seq 1 10); do
  CA=$(kubectl get secret aws-load-balancer-tls -n kube-system -o jsonpath='{.data.ca\.crt}')
  for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
    count=$(kubectl get "$kind" aws-load-balancer-webhook -o json | jq '.webhooks | length')
    for idx in $(seq 0 $((count-1))); do
      kubectl patch "$kind" aws-load-balancer-webhook --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/webhooks/${idx}/clientConfig/caBundle\", \"value\":\"$CA\"}]" >/dev/null
    done
  done
  # 20초 뒤에도 유지되는지 확인 — sync가 덮으면 여기서 걸린다
  sleep 20
  ok=1
  for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
    uniq=$(kubectl get "$kind" aws-load-balancer-webhook -o json | jq -r '[.webhooks[].clientConfig.caBundle] | unique | length')
    got=$(kubectl get "$kind" aws-load-balancer-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}')
    [ "$uniq" = "1" ] && [ "$got" = "$CA" ] || ok=0
  done
  [ "$ok" = "1" ] && { echo "CABUNDLE_OK (시도 ${attempt}회)"; break; }
done
```

검증 조건 두 가지를 모두 본다 — **모든 webhook 항목의 값이 하나로 통일**(`unique | length == 1`)
되어 있고, 그 값이 **Secret의 `ca.crt`와 일치**해야 한다. 항목별로 값이 갈려 있으면 일부만
patch된 상태다.

이 루프를 거쳤다면 3-B-3-2(사후 대응)는 발생하지 않는다. 그럼에도 Ingress가 ALB를 못 받으면
caBundle이 아니라 다른 원인이므로 3-B-3(webhook 미기동)이나 LBC 로그를 확인한다.

> **WHY — 왜 매번 어긋나는가 (2026-08-03 업스트림 차트 확인)**: `aws/eks-charts`의
> `_helpers.tpl` → `aws-load-balancer-controller.webhookCerts` 헬퍼는 기존 Secret을
> `lookup`으로 찾으면 재사용하고, **못 찾으면 `genCA`/`genSignedCert`로 새 인증서를 만든다.**
> ArgoCD는 `helm template`(클라이언트 렌더링)을 쓰므로 `lookup`이 항상 빈 값을 반환해
> **sync마다 `genCA` 경로를 타고 새 `caBundle`이 나온다.** devops-manifest도 이 사실을
> 알고 `ignoreDifferences`(caBundle·Secret `/data`)와 `RespectIgnoreDifferences=true`를
> 이미 걸어놨지만(`argocd/applicationsets/eks-addons/hub/aws-load-balancer-controller.yaml`),
> 초기 sync가 수렴하는 동안에는 patch가 덮이는 경우가 실제로 관찰됐다 — 그래서 1회 patch로는
> 부족하고 검증·재시도가 필요하다.
>
> **근본 해결책은 `enableCertManager: true`다**(차트가 `caBundle`을 렌더링하지 않고
> `cert-manager.io/inject-ca-from` 어노테이션으로 cainjector가 주입 — 렌더링마다 인증서가
> 바뀌는 구조 자체가 사라진다). 이 프로젝트는 cert-manager를 EKS 관리형 애드온으로 이미
> 설치하므로 values 한 줄로 전환 가능하나, **LBC에 cert-manager를 붙이는 구성이 일반적이지
> 않다고 판단해 채택하지 않았다**(2026-08-03 결정). 채택하려면 devops-manifest 변경이므로
> 요청서를 작성해야 한다.
>
> **WHY — 선제 patch 자체의 근거 (2026-08-03 실측)**: 이전엔 "감지 시 대응"(3-B-3-2)으로만
> 쓰여 있어 Step 5 검증에서 Ingress에 ADDRESS가 비어있는 걸 보고서야 발견했고, 그 사이
> 8분 26초 동안 LBC가 `x509: certificate signed by unknown authority`로 재시도만 반복했다 —
> 정작 patch는 13초로 끝났다. 선제 patch 도입 후 같은 손실이 20초(재patch)로 줄었고,
> 위 검증 루프까지 넣으면 그 재작업도 자동 흡수된다.

**3-B-2. addon 등록 확인 — 완전 자동화, 수동 개입 불필요 (2026-07-22 재확인)**

> 아래는 여러 차례에 걸쳐 갱신되던 절차였는데, 지금은 사람이 할 일이 없는 상태로
> 정리됐다 — devops-manifest를 직접 클론해 각 항목을 재확인했다:
> - `root-app-addons.yaml`은 devops-manifest에 정적 파일로 더 이상 존재하지 않는다
>   (devops-manifest 커밋 `9a5cc4d`로 삭제 — Terraform 자동 부트스트랩과 소유권 경합
>   방지). 이 root(monitoring)의 `bootstrap/root-app-addons.yaml`(`main.tf`가
>   `templatefile()`로 읽어 `gitops_bridge_hub.apps.addons`로 전달)이 유일한 source다
>   — `terraform apply`만으로 자동 생성되고, `kubectl apply`나 `gh api` 수동 등록 절차는
>   더 이상 없다.
> - devops-manifest가 `argocd/applicationsets/eks-addons/`를 `hub/`·`spoke/` 서브폴더로
>   분리했다(커밋 `ca3f614`). `bootstrap/root-app-addons.yaml`의 `directory.recurse: true`
>   (2026-07-22 반영)가 이 서브폴더까지 재귀적으로 읽는다 — 같은 경로에 있는
>   `_project.yaml`(AppProject, 옛 `argocd/projects/eks-addons.yaml`에서 이미 이쪽으로
>   이동함)도 이 재귀 스캔에 포함되므로 별도 부트스트랩이 필요 없다.
> - addon 17개(hub 10 + spoke 7) 전부 `syncPolicy.automated: {prune: true, selfHeal:
>   true}`다(devops-manifest 커밋 `5ac4e68` — 라이브에서 `Manual`이던 시절과 달리 지금은
>   `argocd app sync` 수동 실행이 필요 없다).
> - `eks-addons` AppProject의 `destinations`에 `{namespace: '*', server:
>   https://kubernetes.default.svc}` 와일드카드 항목이 이미 있어(devops-manifest 커밋
>   `da6e5bb`) cluster-scoped Application(`karpenter-resources` 등)의
>   `InvalidSpecError`는 재현되지 않는다.
> - `argo-rollouts`/`external-dns`/`external-secrets`/`karpenter` 4개 addon 전용
>   namespace도 각 ApplicationSet에 `CreateNamespace=true`가 이미 있어(직접 확인)
>   fresh apply에서 namespace 부재로 막히지 않는다.

`terraform apply` 완료 후 확인만 한다:

```bash
kubectl get application -n argocd -l app.kubernetes.io/component=addon
```

17개(hub 10 + spoke 7) 전부 `Synced`/`Healthy`인지 확인한다. LBC의 mutating webhook이 아직
준비되지 않은 상태에서 다른 addon이 먼저 reconcile를 시도하면 일시적으로
`no endpoints available for service "aws-load-balancer-webhook-service"` 에러가 보일 수
있다 — automated `selfHeal`이 재시도하므로 보통 자동으로 해소된다. 몇 분 뒤에도 안 풀리면
아래 3-B-3 참고.

**[측정] 이 sync 안정화 대기는 반드시 시간을 기록한다.** 폴링으로 흘려보내기 쉬운 구간인데
실측상 provision 벽시계의 상당 부분을 차지하며, 기록이 없으면 "어디서 시간이 갔는지"가
설명되지 않는다(2026-08-03 실측: 단계 합 943s vs 벽시계 2453s의 격차 대부분이 이 구간과
caBundle 발견 지연이었다):

**[필수] 단순 대기가 아니라 자가복구가 안 되는 두 상태를 각각 다르게 처리하는 루프여야 한다.**

| 고착 상태 | 증상 | 조치 |
|---|---|---|
| **sync 실패 포기** | `status.conditions`에 `SyncError`. ArgoCD는 **5회만 재시도하고 포기**하며 그 뒤에는 `automated selfHeal`이 걸려 있어도 복구하지 않는다 | 재sync 트리거 |
| **stale health** | `Synced/Degraded` 또는 `OutOfSync/Healthy`인데 파드는 Running, 하위 리소스도 정상. `SyncError`가 **붙지 않는다** | `refresh=hard` 어노테이션 |

두 번째가 중요하다 — **`SyncError` 조건만 보는 루프는 stale health를 영원히 못 푼다.**

```bash
s=$(date +%s)
CTX=<대상 클러스터 context>
for i in $(seq 1 40); do
  # jsonpath로 "이름 SYNC HEALTH" 한 줄씩 뽑는다. 컬럼 파싱(awk)을 쓰지 않는 이유는
  # 아래 "[주의] 이 문서에 ＄0~＄9를 쓰지 않는다" 참조.
  out=$(kubectl get application -n argocd --context "$CTX" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null)
  total=$(printf '%s\n' "$out" | grep -c .)
  ok=$(printf '%s\n' "$out" | grep -c ' Synced Healthy$')
  echo "[$i] $ok/$total Synced+Healthy"
  if [ "$total" -ge <기대 개수> ] && [ "$ok" -eq "$total" ]; then echo "SYNC_DONE: $ok/$total"; break; fi
  # [주의] 대상 선정은 SYNC/HEALTH 두 값을 함께 본다 — sync 상태만 보면
  #        Synced/Degraded(= stale health의 대표 형태)가 통째로 누락된다.
  for app in $(printf '%s\n' "$out" | grep -v ' Synced Healthy$' | cut -d' ' -f1); do
    if kubectl get application "$app" -n argocd --context "$CTX" -o json 2>/dev/null \
      | jq -e '.status.conditions[]? | select(.type=="SyncError")' >/dev/null 2>&1; then
      # (1) 포기한 앱 — 재sync 트리거. selfHeal은 이걸 복구하지 못한다
      kubectl patch application "$app" -n argocd --context "$CTX" --type merge \
        -p '{"operation":{"initiatedBy":{"username":"provision-retry"},"sync":{"revision":"HEAD"}}}' >/dev/null 2>&1
    elif [ "$i" -ge 6 ]; then
      # (2) SyncError가 없는데도 6회(약 2분) 이상 안 풀림 → stale health로 보고 하드 리프레시
      kubectl annotate application "$app" -n argocd --context "$CTX" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1
    fi
  done
  sleep 20
done
e=$(date +%s); printf '%-34s %5ds\n' "Step 3-B-2 ArgoCD sync 안정화" "$((e-s))" | tee -a "$RUN_DIR/timing.log"
```

> **WHY — stale health 분기 (2026-08-07~08-09 실측, 4회 재현)**: `argo-rollouts`,
> `aws-load-balancer-controller`가 `Synced/Degraded`로, `notifications-resources`가
> `OutOfSync/Healthy`로 고착됐다. 매번 파드는 `1/1 Running`, Deployment는 `Available`,
> 하위 리소스 중 unhealthy로 보고된 것이 하나도 없었고 `.status.sync.status`를 직접
> 조회하면 이미 `Synced`였다 — **ArgoCD 목록 뷰의 판정만 낡은 상태**였다.
> `SyncError` 조건이 안 붙으므로 재sync 분기가 전혀 발동하지 않아 루프가 대기만 했다.
> `refresh=hard` 한 번이면 다음 폴링에서 해소된다. 6회부터 거는 이유는 초기 기동 중
> 정상적으로 `Progressing`인 앱까지 매 회차 하드 리프레시로 때리지 않기 위해서다
> (실제로 `argo-rollouts`가 5회차까지 진짜 rollout 진행 중이었다가 자연 해소된 사례가 있다).

> **WHY (2026-08-03 실측)**: `notifications-resources`가 ESO webhook 기동 전에 sync를 시도해
> `no endpoints available for service "external-secrets-webhook"`로 실패했고, ArgoCD가
> `(retried 5 times)` 후 포기해 `OutOfSync/Missing`으로 고착됐다. 그 시점엔 ESO webhook 파드가
> 이미 `Running`이고 엔드포인트도 정상이었으므로 **재sync 한 번이면 되는 상태였는데**, 루프가
> 단순 대기만 해서 687초(폴링 상한 40회)를 전부 쓰고 타임아웃됐다 — 수동 재sync 후 복구까지
> 걸린 시간은 **5초**였다. 즉 손실 전체가 "복구되지 않을 상태를 기다린 시간"이다.
>
> ESO webhook 경쟁 자체는 3-A-4·3-B-3과 같은 부류의 알려진 일시적 문제이고, 이 루프가
> 그 복구까지 흡수하면 별도 대응 단계가 필요 없어진다.

**3-B-3. sync 중 LBC 웹훅 경쟁 감지 시**

- `no endpoints available for service "aws-load-balancer-webhook-service"`

LBC 파드가 `Running`인지 재확인 후 실패한 addon의 sync만 재실행한다(최대 2회).

**3-B-3-2. [백업 경로] Ingress/ALB 생성 시 x509 unknown authority 감지 시 (webhook caBundle
불일치 — 3-B-3과 다른 문제)**

> **이 절은 3-B-1.7(선제 patch)을 어떤 이유로 건너뛰었거나, patch 이후 새로 만들어진
> Ingress에서 같은 증상이 재발한 경우에만 쓴다.** 정상 절차에서는 3-B-1.7이 이미
> 처리하므로 여기까지 오지 않는다 — 아래 내용은 원인 설명과 복구 절차의 상세 근거다.

`kubectl describe ingress`나 LBC 로그에 아래 패턴이 보이면 3-B-3(webhook 아직 미기동)과는
다른 원인이다 — webhook 서비스 자체는 응답하지만 TLS 인증서 체인이 안 맞는 상태다:

- `x509: certificate signed by unknown authority (... "aws-load-balancer-controller-ca")`
- `remote error: tls: bad certificate` (LBC 파드 로그)

**원인**: `aws-load-balancer-controller` Helm chart가 `ValidatingWebhookConfiguration`/
`MutatingWebhookConfiguration`의 `caBundle`을 차트 렌더링 시점에 고정값으로 굽는다
(`kubectl get validatingwebhookconfiguration aws-load-balancer-webhook -o yaml`의
`last-applied-configuration` 확인 시 정적 caBundle이 박혀있음). 반면 LBC 파드 자신은
매 fresh 기동마다 스스로 새 self-signed CA+cert를 생성해 `aws-load-balancer-tls` Secret에
쓴다. eks-addons destroy→재provision으로 클러스터가 완전히 새로 생기면 이 둘이 서로 다른
세대의 인증서를 가리키게 되어 webhook 호출이 항상 실패한다.

**검증된 해결 절차 — 이름 기준으로 9개 webhook 항목 전체를 한 번에 patch한다 (index
추측·부분 patch·파드 재시작은 전부 불필요하고 시간만 소모함, 2026-07-29 monitoring
provision에서 실제로 index 0/1만 patch → 재확인 → 파드 재시작 → 나머지 재발견의 순서로
30분 가까이 낭비한 뒤 아래 방식으로 확정):

```bash
CA=$(kubectl get secret aws-load-balancer-tls -n kube-system -o jsonpath='{.data.ca\.crt}')
for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
  count=$(kubectl get "$kind" aws-load-balancer-webhook -o json | jq '.webhooks | length')
  for idx in $(seq 0 $((count-1))); do
    kubectl patch "$kind" aws-load-balancer-webhook --type='json' \
      -p="[{\"op\": \"replace\", \"path\": \"/webhooks/${idx}/clientConfig/caBundle\", \"value\":\"$CA\"}]" >/dev/null
  done
done
```

패치 후 실패했던 Ingress에 아무 annotation이나 touch해 admission을 재시도시킨다(같은 값
재적용도 무방, 목적은 API 서버가 해당 객체를 다시 admission review에 태우는 것뿐이다):

```bash
kubectl annotate ingress <name> -n <namespace> force-reconcile="$(date +%s)" --overwrite
```

**[주의] `kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration
aws-load-balancer-webhook`로 지우고 재생성을 유도하는 방법은 시도하지 않는다** — 실제로
검증해본 결과 ArgoCD/Helm이 수 초 내로 재생성하긴 하지만, 그 재생성本이 Helm 차트에 구운
바로 그 옛 정적 caBundle이라 원인이 전혀 해소되지 않는다(2026-07-29 monitoring에서 실측 —
delete 후 재생성된 9개 항목 전부 다시 mismatch로 확인, 결국 위 patch를 재실행해야 했다).
ArgoCD의 `automated selfHeal`이 이 patch를 되돌리지 않는 이유는 `ignoreDifferences`가
caBundle 필드를 추적 대상에서 제외하기 때문으로 보인다(patch 후 Application이 계속
`Synced` 유지, `OutOfSync`로 전환되지 않음) — 즉 **패치는 안전하게 유지되지만, 객체 자체를
지우면 그 보호가 의미 없어진다.**

**3-B-4. ESO/Karpenter가 뜬 뒤 나머지 Terraform 리소스 apply**

3-B-2에서 ExternalSecrets와 Karpenter의 sync가 `Healthy`인지 확인한 뒤:

```bash
cd {root}/eks-addons && terraform apply -auto-approve
```

> **참고 (2026-07-18 Phase 6-4 완료 후 갱신)**: monitoring은 ESO의 ClusterSecretStore/
> ExternalSecret(image-updater git-creds, notifications Slack 토큰 등)과 Karpenter의
> NodeClass/NodePool까지 전부 GitOps Bridge로 이관 완료되어, 이 root에는 더 이상 ArgoCD
> 관리 CRD에 의존하는 Terraform 리소스가 없다 — 이 apply는 통상 `0 to add, 0 to change,
> 0 to destroy`(no-op)로 끝난다. 이 단계는 앞으로 새 addon이 추가되거나 develop/
> production이 GitOps Bridge로 전환되어 같은 패턴(CRD 의존 리소스)이 다시 생길 경우를
> 대비해 절차만 남겨둔다.

아래 에러가 나오면 해당 addon(ESO 또는 Karpenter)의 sync가 아직 `Healthy`가 아니라는
뜻이니 `argocd app get <name> --core`로 상태를 재확인한 뒤 재시도한다:

- `no matches for kind "EC2NodeClass" in group "karpenter.k8s.aws"`
- `no matches for kind "ClusterSecretStore" in group "external-secrets.io"`

**3-B-5.** 위 패턴에 해당하지 않는 다른 에러는 재시도하지 말고 사용자에게 보고 후 중단한다.

### Step 3.5: observability 루트 apply — LGTM 저장소/IAM/Pod Identity (observability root가 있는 환경만 — 현재 monitoring)

`{root}/observability`가 존재하는 환경(monitoring)만 실행한다. 없으면 이 단계를 건너뛴다.

**LGTM(Loki/Mimir/Tempo/Grafana)은 monitoring 클러스터에만 구축된다** — monitoring이 관측성
백엔드 Hub이고, develop/production에는 observability 루트도 LGTM 워크로드도 없다(dev/prod는
자기 텔레메트리를 monitoring Hub로 보내는 spoke이며 LGTM 백엔드를 직접 돌리지 않는다). 따라서
이 Step은 monitoring provision에서만 수행된다.

이 root는 LGTM 스택(Loki/Mimir/Tempo)의 S3 버킷 3개 + 버킷별 IAM Role 3개 + **EKS Pod Identity
Association 3개**를 만든다. **Pod Identity Association은 EKS 클러스터의 하위 리소스라 teardown 시
클러스터와 함께 AWS가 자동 삭제**하므로, 재provision 때 반드시 재apply해 새 클러스터로 다시
연결해야 한다 — 빠뜨리면 LGTM 파드가 S3 자격증명을 못 받아 Grafana 등이 기동 실패한다.

이 root의 `data.aws_eks_cluster`가 클러스터 존재를 전제하므로 **반드시 Step 2(클러스터 생성)
이후**에 실행한다. 다만 **eks-addons와는 별도 state이고 리소스가 겹치지 않으므로 Step 3의
apply와 동시에 백그라운드로 실행한다**(직렬로 기다리지 말 것 — 이 apply는 ~1분, eks-addons는
~5분이라 그냥 묻힌다):

```bash
cd {root}/observability && terraform apply -auto-approve
```

- S3 버킷/IAM Role은 teardown에서 유지됐다면 그대로 재사용되고(변경 없음), Association만
  새 클러스터로 재생성된다(state에 남아있던 옛 Association은 refresh 시 사라진 것으로 감지되어
  교체된다).
- LGTM 차트 자체(Loki/Mimir/Tempo/Grafana Helm)는 이 Terraform이 아니라 devops-manifest의
  ArgoCD(observability ApplicationSet/app-of-apps)가 배포한다 — workload 앱과 마찬가지로 이
  스킬의 Terraform 범위 밖이다. Grafana admin 자격증명은 SSM→ESO 경로이며, 그 SSM 경로
  (`/eks-practice/monitoring/grafana/*`)는 ESO IRSA 정책(eks-addons/locals.tf의
  `external_secrets_ssm_parameter_arns`)에 이미 포함되어 있어야 한다.

### Step 4: cross-account ExternalDNS 신뢰 정책 갱신 (조건부)

> **[선행 조건] 이 환경의 eks-addons apply가 `Apply complete!`를 찍은 뒤에 실행한다.**
> `project/global/ap-northeast-2/external-dns-cross-account-role` root는
> `data.terraform_remote_state.monitoring_eks_addons.outputs.external_dns_role_arn`을
> 참조하므로, eks-addons가 아직 적용되지 않았으면 그 state에 output이 하나도 없어
> `plan` 단계에서 통째로 실패한다:
>
> ```
> Error: Unsupported attribute
>   data.terraform_remote_state.monitoring_eks_addons.outputs is object with no attributes
> ```
>
> **WHY (2026-08-07 실측)**: 이 스킬의 "의존성이 없는 것은 무조건 병렬로 돌린다" 원칙과
> 의존성 표만 보고 eks-addons apply와 Step 4를 동시에 시작했다가 위 에러로 실패했다 —
> 표에 이 행이 없어서 "병렬 가능"으로 읽힌 것이 원인이다. eks-addons 완료 후 재실행하면
> 15초에 끝난다. 표에도 같은 행을 추가해 두 곳이 어긋나지 않게 했다.

`{root}/eks-addons/*.tf`에서 `external_dns_cross_account_role_arn` 문자열을 Grep한다.

**매치 없음** (예: develop — 같은 워크로드 계정 내 Route53이라 cross-account 불필요):

```
[안내] 이 환경은 cross-account ExternalDNS를 사용하지 않습니다. 이 단계를 건너뜁니다.
```

Step 5로 진행.

**매치 있음** (현재 monitoring):

1. `cd project/global/ap-northeast-2/external-dns-cross-account-role && terraform plan -out=tfplan`
2. plan 결과에 `aws_iam_role.external_dns_cross_account_role`의 `assume_role_policy` 변경이
   없으면(`No changes`) "[안내] 신뢰 정책이 이미 최신 상태입니다." 출력 후 `rm -f tfplan`, Step 5로.
3. 변경이 있으면 (IRSA 역할 재생성으로 unique ID 불일치 — plan에 `AROA...` → `arn:aws:iam::...role/...`
   형태로 나타남) `terraform apply tfplan` 실행 후 `rm -f tfplan`.

   > **WHY**: IAM 트러스트 정책의 `Principal.AWS`에 역할 ARN을 넣으면 AWS는 이를 역할의
   > unique ID로 내부 변환해 저장한다. eks-addons destroy로 ExternalDNS IRSA 역할이 삭제되고
   > 재생성되면 같은 이름이라도 새 unique ID를 받는다. 이 갱신 없이는 새 ExternalDNS가
   > workload 계정 Route53에 대한 `sts:AssumeRole`을 거부당해 DNS 레코드를 생성하지 못한다.

4. `cd {root}/eks-addons && terraform apply -auto-approve` 재실행 (통상 no-op이지만
   상태 일치를 확인하기 위해 실행한다).

### Step 5: 검증

1. `kubectl get pods -A`로 `Running`/`Completed`가 아닌 파드가 있는지 확인, 있으면 경고 출력
2. **3-B(GitOps Bridge) 절차를 탔다면 추가로** `argocd app list --core`로 3-B-2에서 등록한
   addon Application들의 `SYNC STATUS`/`HEALTH STATUS`가 모두 `Synced`/`Healthy`인지 확인한다.
   `OutOfSync`나 `Degraded`가 있으면 `argocd app get <name> --core`로 원인을 확인 후 보고한다
   (3-A 절차만 탄 환경은 이 항목을 건너뛴다 — addon이 전부 Terraform Helm이라 별도 확인 불필요).
3. `kubectl get ingress -A`로 각 Ingress에 ALB 주소(ADDRESS)가 할당됐는지 확인하고,
   **`kubectl get svc -A --field-selector spec.type=LoadBalancer`로 NLB도 함께 확인한다**
   (OTel Gateway처럼 Ingress가 아니라 Service로 LB를 만드는 컴포넌트가 있다 — `EXTERNAL-IP`가
   `<pending>`에서 안 넘어가면 LBC 로그를 확인한다). teardown에서 이 종류를 놓치면 LB가 고아로
   남아 계속 과금되므로, provision 단계에서 존재를 파악해두는 것 자체가 안전망이다.
4. Ingress가 있으면 `external-dns.alpha.kubernetes.io/hostname` 값을 각각 확인하고,
   `{root}/eks-addons/locals.tf`에서 `external_dns_route53_zone_arns`를 Grep해 zone ID를 추출한 뒤:

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
     --query "ResourceRecordSets[?Name=='<hostname>.']"
   ```

   A 레코드의 `AliasTarget.DNSName`이 현재 Ingress의 ALB 주소와 일치하는지 확인
   (최대 2분 polling — ExternalDNS 반영 지연 감안).

5. 완료 안내를 출력한다.

**소요 시간 출력**: `$RUN_DIR/timing.log`를 그대로 보여주고 자동화 구간 합계를 덧붙인다
(공통 처리 "실행 로그 위치와 소요 시간 측정" 참조). `[대기]` 항목은 합계에서 제외하되
표에는 남겨 "사람이 기다린 시간"과 "절차가 쓴 시간"을 구분해 보여준다.

```
[완료] <환경> 리소스 생성 완료
- VPC NAT Gateway: 활성화
- EKS 클러스터: <cluster_name>
- eks-addons: 생성 완료
- Ingress: <hostname 목록과 상태>

[소요 시간]  (로그: <RUN_DIR>)
Step 1+2 VPC NAT + EKS (병렬)         845s
Step 3 eks-addons (mon)               412s
Step 3 eks-addons (dev)               298s
Step 3.5 observability                 96s
[대기] SSO 재로그인                    150s
──────────────────────────────────────────
총 소요(자동화 구간 합)               1651s
```
