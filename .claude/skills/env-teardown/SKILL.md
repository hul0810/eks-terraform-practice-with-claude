---
name: env-teardown
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(eks-addons, EKS 클러스터, VPC NAT Gateway)를
  역순으로 삭제한다. terraform destroy만으로는 정리되지 않는 잔여 리소스
  (ArgoCD Application/ApplicationSet가 재조정 중인 Ingress·ALB, workload 계정 Route53에
  ExternalDNS가 만든 레코드, VPC CNI secondary ENI 잔존, 삭제된 클러스터를 가리키는
  ~/.kube/config 잔여 context/cluster/user 항목, Terraform state가 영향을 받는 addon
  IAM/AWS 리소스 사후 검증, monitoring의 LGTM 스택(Loki/Mimir/Tempo/Grafana) StatefulSet
  PVC가 남기는 고아 EBS 볼륨 회수 및 observability 루트의 S3 데이터 비우기)까지 함께 관리한다.
  observability의 S3 버킷·IAM Role·Pod Identity Association(클러스터와 함께 자동 삭제됨)은
  유지한다. VPC 자체·서브넷·파라미터 스토어 등 비용이 없는 리소스는 삭제하지 않는다. 3개
  환경 모두 실습용이므로 production도 대상이다.
disable-model-invocation: false
allowed-tools:
  - Bash(terraform *)
  - Bash(aws *)
  - Bash(kubectl *)
  - Bash(curl *)
  - Read
  - Grep
  - Glob
  - Edit
---

## 사용법

`$ARGUMENTS`로 대상 환경을 받는다: `monitoring` / `develop` / `production`.

```
/env-teardown monitoring
/env-teardown develop
/env-teardown production
```

## 실행 절차

### Step 0: 환경 파라미터 결정 및 확인

`$ARGUMENTS` 검증은 `/env-provision`과 동일하다 (없으면 안내 후 중단).

**환경별 root 디렉토리**:

| 환경 | root |
|------|------|
| monitoring | `monitoring/environments/ap-northeast-2/shared` |
| develop | `project/environments/develop/ap-northeast-2/shared` |
| production | `project/environments/production/ap-northeast-2/shared` |

진행 전 아래를 요약해 보여준다:

```
[삭제 대상] <환경>
- eks-addons (helm release 전체, ArgoCD/Karpenter/LBC/ExternalDNS/external-secrets 등)
- EKS 클러스터 (<cluster_name>)
- VPC NAT Gateway (VPC 자체는 유지)
```

`monitoring` / `develop`는 확인 없이 바로 Step 1로 진행한다 — 3개 환경 모두 실습용이고
비용 발생 리소스만 대상이므로 매번 y/N을 묻지 않는다.

`production`만 예외로 진행 전 확인을 받는다 (다른 환경보다 실수 시 파급력이 크므로):

```
[확인] production 환경의 리소스를 삭제합니다. 계속할까요? (y/N)
```

`y`가 아니면 중단한다.

> **여러 환경을 함께 삭제할 때 순서 — spoke(develop/production) 먼저, monitoring(Hub) 나중
> (2026-07-22 확인)**: monitoring의 `gitops-bridge-registry.tf`가 만드는
> `gitops_bridge_registry_writer` Role(spoke별 계정 하나씩)을, develop/production의
> `gitops-bridge-registry.tf`(spoke 쪽)가 자기 SSM Parameter Store 등록 항목을 정리할 때
> assume한다. monitoring을 먼저 destroy하면 이 Role이 사라져 spoke의 `eks-addons destroy`가
> provider 단계에서부터 `Cannot assume IAM Role`로 전체가 막힌다(state rm으로 리소스만
> 빼도 provider 블록 자체가 선언돼 있으면 Terraform이 여전히 그 provider 설정을 평가하려
> 시도한다 — 소용없음). 이 경우 `providers.tf`의 `aws.gitops_bridge_registry` provider
> 블록과 `gitops-bridge-registry.tf`의 `aws_ssm_parameter.gitops_bridge_registry` 리소스를
> 임시로 주석 처리해야 destroy가 진행된다(monitoring 재provision 후 함께 복원) — 결과물로
> monitoring 계정에 SSM Standard tier 파라미터(비용 없음)가 고아로 남는다. `monitoring
> develop 둘 다 삭제해줘`처럼 여러 환경을 한 번에 받으면 **항상 spoke(develop/production)를
> 먼저 끝내고 monitoring을 마지막에 처리한다** — spoke가 아직 살아있는 동안 monitoring을
> 먼저 지우면 이 문제가 반드시 재현된다.

> **`monitoring` 단독 호출 시에도 항상 아래 체크를 Step 6 진입 전에 수행한다 (2026-07-23
> 갱신 — 실제 고아 SSM 파라미터 재현)**: 위 순서 규칙은 "한 요청에 여러 환경"일 때만이
> 아니라, `/env-teardown monitoring`을 단독으로 호출해도 develop/production이 과거
> 세션에서 이미 spoke로 등록된 채 남아있을 수 있어 동일하게 적용된다(2026-07-23 develop
> 재provision 중 `ParameterAlreadyExists`로 실제 재현 — 원인은 이전 세션이 이 순서를
> 지키지 않고 monitoring을 먼저 지운 것). `monitoring`이 대상이면 Step 6 전에 항상:
>
> ```bash
> MSYS_NO_PATHCONV=1 aws ssm get-parameters-by-path --path "/eks-practice/gitops-bridge/spokes" \
>   --recursive --profile terraform-monitoring --query "Parameters[].Name" --output text
> ```
>
> (Git Bash에서 `/`로 시작하는 인자는 Windows 경로로 오변환되니 `MSYS_NO_PATHCONV=1` 필수.)
> 결과가 비어있지 않으면 Step 6을 진행하지 않고 중단한다 — 경로에서 계정 ID/클러스터
> 이름을 읽어 "먼저 `/env-teardown <해당 spoke 환경>`을 실행하라"고 안내한다. 사용자가
> "그래도 진행"을 명시적으로 요청하면(예: 그 spoke가 이미 별도 경로로 완전히 삭제된 게
> 확실한 경우) 진행하되, SSM에 고아 파라미터가 남을 수 있음을 미리 알린다.

> **참고**: `production`은 `.claude/hooks/block-production-apply.sh`(PreToolUse 훅)가
> `environments/production` 경로의 `terraform apply`를 기본적으로 차단한다
> (`terraform destroy`는 정규식 대상이 아니므로 차단되지 않는다). 즉 Step 6·8의
> `terraform destroy`는 그대로 진행되지만, Step 10의 NAT Gateway 비활성화(`terraform apply`)는
> 훅에 막힌다. production teardown도 실습 예외 대상이므로, Step 10에서는 명령 앞에
> `ALLOW_PRODUCTION_TEARDOWN_APPLY=1` 마커를 붙여 실행한다 (`docs/environment-teardown.md`
> "production teardown — 보호 원칙과 실습 예외" 참고). 이 마커는 해당 명령 1회에만 적용되며,
> teardown 목적 외에는 절대 사용하지 않는다.

### 공통 처리: [주의] 이 문서에 `＄0`~`＄9`를 쓰지 않는다 — 슬래시 명령 인자로 치환된다

**이 SKILL.md가 로드될 때 본문의 `＄0`~`＄9`가 슬래시 명령의 위치 인자로 그대로 치환된다.**
`＄0`은 첫 번째 인자, `＄1`은 두 번째 인자로 바뀌며, 인자 개수만큼만 치환되므로 **인자를
몇 개 주느냐에 따라 깨지는 위치가 달라진다** — 파일 원문은 멀쩡한데 로드된 내용만 틀리는
형태라 눈치채기 어렵다. **이 섹션의 예시는 전각 `＄`로 적었다** — 반각으로 적으면 이
설명문 자체가 치환돼 앞뒤가 같은 줄이 되어버린다:

```bash
# 파일 원문
SSO_SESSION=$(awk -v p="[profile $PROFILE]" '＄0==p{f=1;next} ...' ~/.aws/config)
# /env-teardown develop monitoring 으로 로드했을 때 실제로 보이는 것
SSO_SESSION=$(awk -v p="[profile $PROFILE]" 'develop==p{f=1;next} ...' ~/.aws/config)
```

따라서 이 문서의 셸·awk 스니펫에서는 위치 필드 참조를 쓰지 않는다. 대안:

| 하려던 것 | `$N` 대신 |
|---|---|
| `kubectl` 출력에서 열 뽑기 | `-o jsonpath`로 필요한 값만 출력하고 `grep`/`cut`으로 처리 |
| 특정 열 값으로 필터 | 줄 전체 패턴(`grep ' Synced Healthy$'`)으로 매칭 |
| ini 파일에서 키 값 추출 | `sed -n '/^\[블록\]/,/^\[/p' | sed -n 's/^키[[:space:]]*=[[:space:]]*//p'` |

`$NF`·`${i}`·`$((...))`·`$VAR`는 치환 대상이 아니므로 그대로 써도 된다 — **숫자 하나짜리
`＄0`~`＄9`만** 문제다(`env-provision` SKILL.md 동일 섹션 참조).

> **WHY (2026-08-10 발견)**: 아래 SSO 알림 루프의 `awk '＄0==p{...}'`가 이 결함을 갖고
> 있었다. 실행에는 영향이 없었지만(명령은 매번 직접 작성했다) **이 문서만 보고 따라가는
> 세션은 깨진 awk를 그대로 쓰게 된다.**

### 공통 처리: AWS SSO 토큰 만료 감지 및 반복 Slack 알림 (Step 1 이후 모든 terraform 명령에 적용)

이 스킬이 실행하는 어떤 `terraform apply`/`destroy`/`plan` 출력에서든 아래 패턴이 보이면
SSO 세션이 만료됐을 수 있다:

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
같은 명령을 1회 재시도한다**(`[실패]` 접두사로 timing 기록). teardown은 지연이 곧 과금이라
불필요한 사람 대기를 넣지 않는 것이 특히 중요하다. 재시도도 같은 이유로 실패하면 그때
사용자에게 보고한다.

> **WHY (2026-08-09 실측, `/env-provision`에서 발생 후 두 스킬에 동일 반영)**: develop
> provision의 Hub 재apply가 `No valid credential sources found`로 실패해 SSO 만료로
> 판단하고 알림 루프를 띄운 뒤 사용자에게 재로그인을 요청했다. 실제 원인은 네트워크였다 —
> `GetRoleCredentials, exceeded maximum number of attempts, 3 ... wsarecv: An existing
> connection was forcibly closed by the remote host.` SSO 토큰은 유효했고(알림 루프가
> 0회차에 즉시 `SSO_RESOLVED`) 재로그인 없이 그대로 재시도해 19초에 성공했다. 세 패턴을
> 동급으로 나열한 것이 오진의 직접 원인이다.

이 상태로 명령이 실패하면 destroy가 중단된 채 비용 발생 리소스(NAT Gateway, EKS 클러스터 등)가
그대로 남아 계속 과금된다. 감지 즉시 아래 백그라운드 루프를 시작한다 — LLM 턴을 소비하지 않는
순수 쉘 루프이므로 10초 간격 반복이 부담 없다 (`run_in_background: true`, `timeout: 600000`
— Bash 도구가 허용하는 최대 10분):

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
    echo "SSO_RESOLVED (반복 ${i}회 후 감지)"
    break
  fi
  if [ -n "$WEBHOOK" ]; then
    msg=$(printf '<!channel> ⚠️ SSO_LOGIN_REQUIRED — *[%s] teardown 중단*\n실행: `%s`\n방치 시 비용 계속 발생 (반복 %s회)' "$ENV_NAME" "$CMD_HINT" "$i")
    payload=$(jq -nc --arg text "$msg" '{text:$text}')
    printf '%s' "$payload" | curl -s -X POST -H 'Content-type: application/json' --data-binary @- --max-time 5 "$WEBHOOK" >/dev/null 2>&1
  fi
  i=$((i+1))
  sleep 10
done
```

루프 완료 알림을 받으면:
- 출력에 `SSO_RESOLVED`가 있으면 로그인이 확인된 것 — 실패했던 명령을 그대로 재실행한다.
- 10분 타임아웃으로 종료됐는데 `SSO_RESOLVED`가 없으면, 사용자에게 "10분간 로그인이 확인되지
  않았다"고 보고하고 계속 대기할지·중단할지 확인을 받는다 (자동으로 루프를 재시작하지 않는다 —
  체이닝은 복잡도 대비 이득이 작다고 판단해 의도적으로 생략).

> **WHY**: 2026-07-09 monitoring teardown 중 `eks-addons destroy`가 SSO 토큰 만료로 실패했다.
> 채팅 텍스트만으로는 사용자가 다른 작업 중이면 놓치기 쉽고, 그 사이 NAT Gateway·EKS
> 클러스터 등 비용 발생 리소스가 삭제되지 않은 채 계속 청구된다. 사용자는 알림을 주로
> Slack으로 받으며, 이미 전역 `Stop` 훅(`~/.claude/hooks/notify-slack.sh`, `~/.claude/settings.json`)이
> 매 턴 종료 시 Slack에 메시지를 전송하도록 되어 있다 — 하지만 이는 "1회성" 알림이라 사용자가
> 놓치면 그만이다. 이 문제의 핵심은 "로그인할 때까지 반복해서 알려야 한다"는 것인데,
> `ScheduleWakeup`은 최소 간격이 60초이고 매 wakeup마다 실제 LLM 턴을 소비해 10초 간격
> 반복에 부적합하다. 대신 Slack Incoming Webhook에 순수 쉘 루프로 직접 curl하면 LLM 비용
> 없이 10초 간격 반복이 가능하다. Slack Incoming Webhook API에는 알림음을 지정하는 필드가
> 없어(수신자 클라이언트 설정 영역) 사운드 자체는 커스텀할 수 없다 — 대신 `<!channel>` 멘션과
> 고정 키워드(`SSO_LOGIN_REQUIRED`)를 메시지에 포함해, 사용자가 Slack "My Keywords"에 이
> 키워드를 등록해두면 채널이 음소거여도 항상 알림이 오도록 했다 (2026-07-10 실제 백그라운드
> 루프로 10초 간격 반복 전송 및 sentinel 파일 감지 시 자동 종료를 검증 완료 — 반복 5회 후
> `SSO_RESOLVED` 출력 확인).
> `env-provision`은 실패해도 리소스가 새로 생기지 않을 뿐이지만, `env-teardown`은 실패가
> 곧 "삭제되어야 할 리소스가 계속 과금되는 상태"로 직결되므로 이 스킬에만 이 반복 알림
> 로직을 넣었다.
>
> **WHY (로그인 확인 방식을 `aws sts get-caller-identity`에서 로컬 캐시 파일 직접 조회로
> 변경, 2026-07-15)**: 처음엔 매 반복마다 `aws sts get-caller-identity`로 로그인 여부를
> 확인했다. 그런데 2026-07-15 monitoring teardown에서 `aws sso login`을 여러 번 다시
> 해도 뒤이은 `terraform destroy`가 계속 `InvalidGrantException`으로 실패하는 현상이
> 발생했다. 원인은 AWS SSO OIDC의 refresh token이 1회용(사용 즉시 새 토큰으로 교체되는
> rotation) 이라는 데 있었다 — access token이 만료된 상태에서 `get-caller-identity`를
> 호출하면 AWS CLI가 캐시된 refresh token으로 **자동 갱신을 시도하며 그 토큰을 소모**하는데,
> 바로 그 직후 terraform(별도의 Go AWS SDK 인스턴스)이 자체적으로 refresh를 시도하면서
> 이미 소모된(무효화된) refresh token을 읽어 갱신에 실패했다. 즉 "로그인됐는지 확인하려고
> 10초마다 호출하던 API 자체가 terraform의 인증 갱신과 경쟁해 실패를 유발"하고 있었다.
> `aws sso login`으로 새 세션을 받은 직후 중간에 다른 `aws` 명령 없이 바로 terraform을
> 실행하면 정상 동작한다는 점에서 이 레이스 컨디션을 확정했다. 해결책은 로그인 확인 자체를
> AWS API 호출 없이 하는 것이다 — `~/.aws/sso/cache/`에 sso_session 이름의 SHA1 해시를
> 파일명으로 캐시된 토큰 JSON이 있고(`aws configure`/`aws sso login`이 기록), 그 안의
> `expiresAt`을 현재 시각과 로컬에서만 비교하면 AWS를 전혀 호출하지 않고도 "지금 유효한
> 세션이 있는지"를 판단할 수 있다. 이러면 알림 루프가 refresh token에 손을 대지 않으므로
> terraform의 자체 갱신과 절대 경쟁하지 않는다.

### 공통 처리: 시간 단축이 최우선 — "컨트롤러가 필요한 것만 선행, 나머지는 클러스터와 함께 버린다"

삭제가 늦어질수록 비용이 계속 나가므로 **벽시계 시간 단축이 이 스킬의 1순위 목표**다.
아래 원칙으로 판단한다 — 운영 환경의 정석 순서(모든 K8s 오브젝트를 곱게 지우고 클러스터를
지운다)를 따를 이유가 없다.

**선행 처리해야 하는 것은 딱 두 부류다** — 클러스터 밖 AWS 리소스를 만들어 두고,
그 컨트롤러가 죽으면 아무도 회수하지 않는 것:

| 대상 | 왜 선행 | 빠른 처리법 |
|------|---------|-------------|
| Ingress → ALB, **Service type=LoadBalancer → NLB** | LBC가 죽으면 영구 고아 | 오브젝트 삭제 후 LB 소멸만 확인 |
| Karpenter NodeClaim → EC2 | Karpenter가 죽으면 영구 고아 | **`aws ec2 terminate-instances`로 직접 종료**(graceful drain 불필요) |

**나머지 K8s 오브젝트는 전부 손대지 않는다.** Application/ApplicationSet/Deployment/
StatefulSet/namespace는 클러스터를 지우면 etcd와 함께 사라진다 — 지우는 데 드는 시간이
그대로 낭비다.

**기다리지 않고 병렬로 넘기는 것들**:

- **EBS 볼륨**: PVC를 지우고 CSI가 회수하기를 기다리지 말 것. `kubectl get pv`로 **볼륨 ID만
  기록**하고 클러스터를 destroy한 뒤 `aws ec2 delete-volume`으로 직접 지운다(클러스터가
  없어져도 볼륨은 남으므로 안전하며, EKS destroy가 도는 동안 병렬로 처리된다).
- **Route53 레코드**: ExternalDNS는 `upsert-only`라 어차피 사람이 지운다. 호스트명만 미리
  기록해두고 **EKS destroy가 도는 동안** 병렬로 삭제한다.
- **여러 환경**: monitoring이 살아있어야 하는 단계가 **둘** 있다. (1) spoke의
  `eks-addons destroy`는 monitoring의 registry-writer Role을 assume한다. (2) spoke의
  `eks destroy`는 monitoring **NAT Gateway**를 data source로 조회한다(Step 8의 순서 제약
  참조). 따라서 **NAT 비활성화 병렬화는 "환경 내부"까지만** — spoke EKS destroy와 spoke NAT는
  병렬로 돌리되, **monitoring NAT는 모든 spoke EKS destroy가 끝난 뒤**에 시작한다.

**권장 실행 순서 (`monitoring develop` 동시 요청 기준)**:

1. **[병렬]** spoke: Hub의 `argocd/<spoke-cluster>` **cluster Secret 삭제**(재조정 차단 —
   아래 Step 2-0) / Hub: `root-app-addons` 삭제
2. **[병렬]** 전 환경: Ingress·LoadBalancer Service 삭제, Karpenter EC2 직접 terminate,
   EBS 볼륨 ID·Route53 호스트명 기록
3. **[병렬]** LB 소멸 확인(보통 1분 내)
4. spoke `eks-addons destroy` → 완료 후 monitoring `eks-addons destroy`
   (**registry-writer Role 때문에 순서 의존**)
5. **[병렬]** 전 환경 EKS destroy + **spoke NAT만** 비활성화 + **Route53 레코드 삭제 +
   EBS 직접 삭제**
6. spoke EKS destroy 완료 확인 → **그 다음에** monitoring NAT 비활성화
   (**monitoring NAT는 spoke `eks` root의 data source 대상 — Step 8 순서 제약 참조**)
7. 최종 검증(LB·NAT·고아 EBS·EKS·Route53 zone 전체) + `$RUN_DIR/timing.log` 출력

> **WHY (2026-07-31 monitoring+develop teardown 실측)**: 직렬 처리로 develop을 완전히 끝낸
> 뒤 monitoring을 시작해 EKS destroy(각 ~10분)가 겹치지 않았고, spoke Application을 개별
> 삭제하려다 재생성 루프로 ~10분, LGTM PVC→EBS 회수 대기로 ~2분, NodeClaim graceful drain
> 대기로 ~1분이 추가로 소요됐다. 위 순서로 바꾸면 EKS destroy 시간 안에 Route53·EBS·검증이
> 전부 묻힌다.

### 공통 처리: `terraform apply`/`destroy` 출력을 파이프로 볼 때는 반드시 `pipefail`

이 스킬의 모든 `terraform apply`/`destroy` 명령을 실제로 실행할 때(백그라운드 실행 포함)
출력이 길어 `| tail -N`으로 줄여서 보는 경우가 많다. **`pipefail` 없이 파이프로 연결하면
파이프라인 전체의 종료 코드가 마지막 명령(`tail`)의 종료 코드가 되어, `terraform`이 실제로
실패해도 `tail`은 항상 0을 반환한다** — 그 결과 백그라운드 작업 완료 알림에 "completed
(exit code 0)"로 잘못 보고되어 실패가 감춰진다. 반드시 아래 중 하나를 지킨다:

```bash
set -o pipefail && terraform destroy -auto-approve -no-color 2>&1 | tail -60
```

또는 파이프 없이 전체 출력을 받은 뒤 `Apply complete!`/`Destroy complete!`/`Error` 문자열로
직접 성공 여부를 판단한다. 어느 쪽이든, **알림에 찍힌 종료 코드만 믿지 말고 출력 내용을
반드시 눈으로 확인한 뒤에만 다음 Step으로 진행한다.** Step 8(EKS destroy)과 Step 10(NAT
Gateway 비활성화)처럼 병렬로 실행하는 명령은 특히 취약하다 — 하나가 조용히 실패해도 다른
하나의 "완료" 알림만 보고 둘 다 끝났다고 오판하기 쉽다.

> **WHY (2026-07-16, `/env-provision`에서 실제 발생 후 두 스킬에 동일 반영)**: monitoring
> provision 중 VPC와 EKS apply를 SSO 만료 시점에 동시에 실행했다. EKS apply는 실패 직후
> 출력을 직접 확인해 재로그인 절차로 넘어갔지만, VPC apply는 `| tail -30`으로 실행한 뒤
> 백그라운드 알림의 "completed (exit code 0)"만 보고 정상 종료로 오판했다 — 실제로는 VPC
> apply도 같은 SSO 만료로 실패해 NAT Gateway가 전혀 생성되지 않았다. 사용자가 직접
> 지적하고서야 `.output` 파일을 열어 에러를 발견했다. teardown도 Step 8/10을 병렬로 돌리는
> 동일 구조라 같은 함정이 있어 함께 반영한다.

### 공통 처리: 실행 로그 위치와 소요 시간 측정

**로그는 저장소 루트의 `temp/log/`에 쓰고, 실행 5회분만 유지한다.** `temp/`는
`.gitignore`에 등록돼 있어 커밋되지 않는다(`.gitignore:43`). Step 0 진입 직후 아래를
1회 실행해 이번 실행 전용 디렉토리를 만든다:

```bash
LOG_ROOT="<저장소 루트>/temp/log"
RUN_DIR="$LOG_ROOT/teardown-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
# 최신 5개만 남기고 오래된 실행 디렉토리 삭제
ls -1dt "$LOG_ROOT"/teardown-* 2>/dev/null | tail -n +6 | xargs -r -d '\n' rm -rf
echo "RUN_DIR=$RUN_DIR"
```

**[주의] `xargs`에 `-d '\n'`이 반드시 있어야 한다.** 이 저장소의 경로에는 공백이 들어있어
(`바탕 화면`, `개인 프로젝트`, `eks 프로젝트`), 기본 구분자를 쓰면 xargs가 경로 하나를
여러 조각으로 쪼갠다 — `rm -rf`가 존재하지 않는 조각들을 지우려다 `-f` 때문에 조용히
성공하고, **로테이션이 아무 일도 하지 않은 채 통과한다**(2026-08-01 실측: 7개 중 0개 삭제).

이후 이 스킬의 모든 `terraform` 출력은 `$RUN_DIR/<단계이름>.log`로 리다이렉트한다
(예: `> "$RUN_DIR/dev-eks-destroy.log" 2>&1`). `RUN_DIR` 값은 세션 중 계속 재사용해야
하므로 **첫 실행 결과를 기억해두고 이후 명령에 문자열로 직접 넣는다** — Bash 도구는
호출 간 쉘 변수를 유지하지 않는다.

**소요 시간은 단계별로 측정해 `$RUN_DIR/timing.log`에 누적한다.** 각 장기 실행 명령을
아래 형태로 감싼다:

```bash
s=$(date +%s); <실제 명령>; e=$(date +%s); \
  printf '%-34s %5ds\n' "<단계이름>" "$((e-s))" | tee -a "$RUN_DIR/timing.log"
```

**사람 대기 시간(SSO 재로그인 등)은 반드시 별도 항목으로 분리해 기록한다** — 절차
최적화로 줄일 수 없는 시간이라 자동화 구간과 섞이면 어느 단계를 개선해야 하는지
판단이 흐려진다. 접두사 `[대기]`를 붙인다:

```bash
printf '%-34s %5ds\n' "[대기] SSO 재로그인" "$((e-s))" | tee -a "$RUN_DIR/timing.log"
```

Step 11 완료 메시지에 총 소요 시간과 단계별 내역을 함께 출력한다:

```bash
cat "$RUN_DIR/timing.log"
printf '%-34s %5ds\n' "총 소요(자동화 구간 합)" \
  "$(awk '!/^\[대기\]/{gsub(/s$/,"",$NF); t+=$NF} END{print t+0}' "$RUN_DIR/timing.log")"
```

> **WHY (2026-08-01)**: 이 스킬은 "시간 단축이 최우선"을 표방하는데, 정작 어느 단계가
> 얼마를 잡아먹었는지 측정하지 않아 최적화 판단이 매번 기억과 체감에 의존했다. 측정값이
> 남으면 다음 실행에서 개선 효과를 숫자로 검증할 수 있다. 저장소 안(`temp/`)에 두되
> gitignore 대상으로 잡는 이유는, 작업 중 바로 열어볼 수 있는 접근성은 유지하면서 실행
> 산출물을 형상 관리에서는 배제하기 위해서다. 5회분만 유지하는 것은 직전 실행들과의
> 비교에는 충분하면서 무한 누적을 막기 위해서다.

### Step 1: kubectl context 확인

`{root}/eks/providers.tf`에서 `profile`을, `{root}/eks/locals.tf`에서 `cluster_name`을 Grep으로
확인한다. `kubectl config current-context`가 해당 클러스터가 아니면:

```bash
aws eks update-kubeconfig --name <cluster_name> --region ap-northeast-2 --profile <profile> --alias <cluster_name>
```

클러스터에 연결되지 않으면(이미 삭제됐거나 최초 생성 전) Step 2~5를 건너뛰고 Step 6으로 이동한다.

### Step 2: ArgoCD Application/ApplicationSet 삭제 — 2-1-B·2-2·2-3·2-4만 필수, 2-5는 생략한다
(2026-07-30 갱신 — 2-1-B를 2-2보다 앞으로 재배치)

**AWS 비용/고아 리소스 위험이 있는 항목만 이 클러스터가 살아있는 동안 명시적으로 정리한다
— LGTM StatefulSet PVC의 EBS 볼륨(monitoring만, 2-1-B), Karpenter NodeClaim(EC2 인스턴스,
2-2), Ingress/ALB(2-3·2-4) 세 가지다.** 나머지
Application/ApplicationSet은 순수 K8s 오브젝트라 Step 8(EKS destroy)이 클러스터를
지우면 etcd와 함께 자동으로 사라진다 — 남겨봐야 손해가 없으므로 2-5(전체 삭제)는
**기본적으로 실행하지 않는다.** (배경: root-app-addons를 `--all`로 정리하던 옛 절차는
전체 Application이 십여 개뿐이던 시절 "확실하게 정리"가 목적이었지만, self-service
레지스트리 도입 이후 addon마다 `-spoke` ApplicationSet이 추가로 생겨 Application·
ApplicationSet 수가 30개 넘게 늘었고, 아래 WHY의 데드락처럼 지우는 순서 자체가 새로운
위험을 만든다는 게 드러났다 — "다 지운다"의 실익보다 절차 리스크가 커졌다.)

**순서:**

**2-0. spoke(develop/production) 환경이면 Hub의 cluster Secret부터 지운다 — 다른 무엇보다 먼저**

spoke에는 ArgoCD가 없다. Application은 전부 Hub(monitoring)의 ApplicationSet이 `clusters`
generator로 **그 spoke의 cluster Secret을 보고** 만든다. 따라서 spoke 대상 Application을
개별로 지우면 **즉시 전부 재생성된다.** 앱 파드까지 되살아나 Karpenter가 노드를 계속 새로
프로비저닝하므로 NodeClaim drain이 영원히 끝나지 않는다.

```bash
kubectl --context <monitoring-context> delete secret <spoke-cluster-name> -n argocd
```

이 Secret이 사라지면 generator가 대상에서 제외해 **addon Application이 자동으로 정리된다.**
다만 두 가지를 알아둔다:

- `root-app-workload`로 직접 생성된 workload Application(owner 없음)은 자동 삭제되지 않으니
  수동으로 지운다.
- Secret이 없으면 ArgoCD가 spoke에 접근할 수 없어 `resources-finalizer`가 안 풀린다 —
  남은 Application은 `kubectl patch ... -p '{"metadata":{"finalizers":[]}}'`로 정리한다
  (실제 AWS 리소스는 아래 2-2에서 직접 처리하므로 안전하다).

이 Secret은 monitoring `eks-addons`의 Terraform 소유라 state drift가 생기지만, monitoring도
곧 destroy되거나 다음 provision에서 재생성되므로 신경 쓰지 않는다.

> **WHY (2026-07-31 develop teardown 실측)**: 이 단계 없이 Application을 개별 삭제했더니
> 13개가 통째로 재생성됐고, NodeClaim이 drain됐다가 다시 생기는 루프에 빠져 ~10분을
> 날렸다. cluster Secret 삭제 한 번으로 즉시 해소된다.

**2-1. root-app-addons 먼저 (재동기화 경합 차단)**

```bash
kubectl delete application root-app-addons -n argocd --ignore-not-found
kubectl delete applicationset root-app-addons -n argocd --ignore-not-found
```

즉시 둘 다 사라졌는지 확인한다(`kubectl get application,applicationset root-app-addons -n argocd`가
`NotFound`여야 함) — 살아있는 채로 다음 단계로 넘어가면 devops-manifest 디렉터리가
재동기화되며 2-3에서 지운 걸 되살릴 수 있다.

**2-1-A. [monitoring 필수] ArgoCD 자체를 정지시킨다 — `root-app-addons` 삭제만으로는 부족하다**

`root-app-addons`는 addon 계열 Application만 관장한다. **`root-app-observability`(grafana/
loki/mimir/tempo/otel-gateway-resources)와 `root-app-workload`(catalog/gateway/order)는
독립적으로 계속 selfHeal한다** — 2-3에서 Ingress·LoadBalancer Service를 지워도 몇 초 만에
되살아나고, 그때마다 **새 DNS 이름의 ALB/NLB가 새로 생성돼** 이미 기록해둔 삭제 대상 목록이
무효가 된다. 더 나쁜 것은 2-2에서 `karpenter` deployment를 `replicas=0`으로 내려도
ArgoCD가 그 값을 차트 기본값으로 되돌려 노드 재생성이 계속된다는 점이다.

monitoring이 대상이면 **개별 Application을 쫓아다니지 말고 ArgoCD 컨트롤러 자체를 내린다**
— 어차피 클러스터를 지울 것이므로 ArgoCD를 살려둘 이유가 없다:

```bash
kubectl --context <monitoring-context> scale statefulset -n argocd --all --replicas=0
kubectl --context <monitoring-context> scale deploy -n argocd --all --replicas=0
```

`application-controller`는 StatefulSet, 나머지(applicationset-controller, repo-server,
server, redis, notifications, image-updater)는 Deployment라 두 명령이 모두 필요하다.
이 시점 이후 Application/ApplicationSet 오브젝트는 남아있어도 아무것도 조정하지 않으므로
개별 삭제가 불필요해진다(Step 8이 클러스터와 함께 지운다).

> **WHY (2026-08-01 monitoring+develop teardown 실측)**: `root-app-addons`만 지우고
> 진행했더니 grafana ALB와 otel-gateway NLB가 각각 새 DNS로 부활했고(`otelgate-8a819bcb69`
> → `ab445ca2aa`), karpenter가 3차례에 걸쳐 노드를 재생성해 총 9대를 반복 종료해야 했다.
> `karpenter` deployment를 `replicas=0`으로 내려도 ArgoCD가 즉시 되돌린 것이 직접 원인이다.
> ArgoCD 컨트롤러를 내린 직후 재생성이 완전히 멎었다.

**2-1-B. LGTM(observability) 워크로드·PVC 정리 → EBS 볼륨 회수 (observability root가 있는
환경만 — 현재 monitoring, 반드시 2-2보다 먼저 실행)**

**LGTM(Loki/Mimir/Tempo/Grafana)은 monitoring 클러스터에만 구축된다**(monitoring이 관측성
백엔드 Hub — develop/production에는 observability 루트도 LGTM 워크로드도 없다). 따라서 이
단계는 monitoring teardown에서만 해당한다.

`{root}/observability`가 존재하는 환경(monitoring)은 LGTM 스택(Loki/Mimir/Tempo/Grafana)이
StatefulSet PVC로 **EBS 볼륨**을 쓴다(monitoring 최초의 스테이트풀 워크로드). **클러스터를 그냥
destroy하면 이 EBS 볼륨이 삭제되지 않고 고아로 남아 계속 과금된다** — reclaimPolicy=Delete는
PVC가 삭제될 때만 트리거되고 클러스터 destroy는 PVC 삭제를 거치지 않기 때문이다. EBS CSI
컨트롤러가 살아있는 지금(Step 8 이전) 반드시 정리한다.

**[중요] 2-2보다 반드시 먼저 실행한다 — Mimir의 PodDisruptionBudget이 karpenter NodeClaim
drain을 무기한 막는다 (2026-07-30 monitoring teardown 실제 발생)**: 원래 이 단계는 2-4
뒤(2-4-B)에 있었는데, 2-2에서 `karpenter-resources`를 지우고 NodeClaim drain을 기다리는
도중 `mimir-*` PDB들(`ALLOWED DISRUPTIONS: 0`)이 그 노드에 떠있는 `mimir-query-scheduler`
파드의 축출을 계속 거부해 drain이 4분 넘게 멈췄다. karpenter 로그에는 명확한 에러 없이
그냥 재시도만 반복된다 — `kubectl get pdb -A`로 `ALLOWED DISRUPTIONS: 0`인 항목이 있는지,
그 파드가 drain 대상 노드에 있는지 확인하면 원인을 특정할 수 있다. LGTM StatefulSet/
Deployment를 먼저 지워 이 PDB들의 대상 파드 자체를 없애면 이 문제가 원천적으로 발생하지
않는다 — 그래서 이 단계를 2-2보다 앞으로 옮겼다.

**[속도] PVC 삭제 → CSI 회수를 기다리지 않아도 된다.** EBS 볼륨은 클러스터가 사라져도 계정에
그대로 남으므로, **볼륨 ID만 기록해두고 Step 8(EKS destroy)이 도는 동안 `aws ec2
delete-volume`으로 직접 지우는 편이 훨씬 빠르다**(2026-07-31 실측: PVC 삭제→회수 확인에 ~2분
소요, 직접 삭제는 EKS destroy 시간에 묻힌다). 아래 PVC 삭제 절차는 "PDB 때문에 파드를 먼저
없애야 하는" 경우(바로 아래 주의 참조)에만 필요하고, 볼륨 회수 자체가 목적이라면 생략한다.

먼저 EBS 볼륨 ID를 기록한다 — **이 기록은 어느 경로를 택하든 반드시 남긴다**:

```bash
kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' | grep '^vol-'
```

이 프로젝트의 ArgoCD 앱은 resources-finalizer가 없어 **앱만 지워도 관리 리소스가 cascade되지
않는다**(2026-07-30 실측 — 앱 삭제 후에도 StatefulSet/Ingress/PVC가 그대로 Running). 따라서
재조정만 멈추고 리소스는 직접 삭제한다:

```bash
# 1) 재조정 중단 (root-app-observability + 관측성 child 앱). grafana Ingress는 2-3의
#    kubectl get ingress -A 스캔이 이미 잡아 ALB까지 정리됨(별도 처리 불필요) — 단, Route53
#    레코드 기록은 2-3의 host 필드 확인 로직을 함께 따라야 놓치지 않는다(아래 2-3 참고).
kubectl delete application root-app-observability grafana loki mimir tempo observability-resources \
  -n argocd --ignore-not-found --wait=false
# 2) 워크로드 컨트롤러 삭제 → 파드 종료 → PVC 해제
kubectl delete statefulset,deployment --all -n monitoring
for i in $(seq 1 24); do [ "$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l)" -eq 0 ] && break; sleep 5; done
# 3) PVC 삭제 → EBS CSI(살아있음)가 볼륨 자동 삭제
kubectl delete pvc --all -n monitoring
```

기록한 볼륨 ID가 실제로 삭제됐는지 개별 확인한다(여러 ID를 한 번에 조회하면 하나만 없어도
전체가 에러이므로 ID별로):

```bash
for v in <기록한 vol-...>; do
  aws ec2 describe-volumes --region ap-northeast-2 --profile <profile> --volume-ids "$v" \
    --query "Volumes[0].State" 2>&1 | grep -q "InvalidVolume.NotFound" \
    && echo "$v 삭제됨" || echo "$v 잔존 — aws ec2 delete-volume으로 직접 삭제"
done
```

**Pod Identity Association / observability Terraform은 건드리지 않는다**: Association 3개
(loki/mimir/tempo)는 클러스터 destroy(Step 8) 시 AWS가 자동 삭제한다 — 별도 `terraform
destroy`가 불필요하다. 오히려 observability root는 `data.aws_eks_cluster`가 클러스터 존재를
전제하므로, 클러스터가 사라지는 teardown 중에 이 root에 terraform을 돌리면 안 된다.
**버킷·IAM Role은 유지**한다(무료, 다음 provision 시 재사용 — provision 시 observability를
재apply하면 Association이 새 클러스터로 재생성된다, `/env-provision` Step 3.5).

**S3 데이터 비우기 (선택 — 비용 정책상 권장, 사용자 확인 후)**: LGTM이 S3에 쓴 청크/블록/
트레이스는 재생성 사이클마다 누적된다. 버킷 자체는 유지하고 데이터만 비운다:

```bash
for b in <loki/mimir/tempo 버킷명 — {root}/observability/locals.tf의 backends 참조>; do
  aws s3 rm "s3://$b" --recursive --profile <profile>
done
```

**2-2. `karpenter-resources` ApplicationSet(들)을 먼저 지운 뒤에만 Application을 지운다**

self-service 레지스트리 도입 이후 `karpenter-resources`(monitoring-self 전용)와
`karpenter-resources-spoke`(`clusters` generator로 dev/prod spoke마다 Application을
생성) 두 ApplicationSet이 있다 — Application만 지우면 그 owner인 ApplicationSet이
아직 살아있어 즉시 재생성한다(root-app-addons와 동일한 재동기화 경합). 먼저
`kubectl get application <name> -n argocd -o jsonpath='{.metadata.ownerReferences[0].name}'`로
owner ApplicationSet 이름을 확인하고, 그 ApplicationSet부터 지운다:

```bash
kubectl delete applicationset karpenter-resources karpenter-resources-spoke -n argocd --ignore-not-found
kubectl get application -n argocd -o name | grep karpenter-resources | \
  xargs -r -n1 kubectl delete -n argocd --ignore-not-found
```

**[속도] 실습 환경에서는 graceful drain을 기다릴 이유가 없다.** 목적은 "EC2 인스턴스가
과금되지 않게 회수"하는 것 하나뿐이고, 워크로드 무중단은 어차피 teardown 대상이라 의미가
없다. **다만 순서가 중요하다 — 공급 주체(컨트롤러 → NodePool)를 먼저 끊고, 그 다음에
NodeClaim과 EC2를 정리한다.** 아래 4단계를 이 순서 그대로 실행한다:

```bash
# 1) 컨트롤러 정지 — 이게 없으면 아래에서 무엇을 지워도 즉시 재생성된다
#    (monitoring은 2-1-A에서 ArgoCD를 이미 내렸어야 이 scale이 유지된다)
kubectl scale deploy karpenter -n karpenter --replicas=0

# 2) NodePool 삭제 — 공급 템플릿 자체를 제거
kubectl delete nodepool --all --ignore-not-found --wait=false

# 3) NodeClaim: finalizer 제거 "후 반드시 delete까지" 한다
kubectl get nodeclaim -o name | xargs -r -I{} kubectl patch {} --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl delete nodeclaim --all --ignore-not-found --wait=false

# 4) 실제 EC2 종료 — 태그로 조회하면 K8s 오브젝트와 어긋난 인스턴스까지 잡힌다
IDS=$(aws ec2 describe-instances --region ap-northeast-2 --profile <profile> \
  --filters "Name=instance-state-name,Values=running,pending" "Name=tag-key,Values=karpenter.sh/nodepool" \
  --query "Reservations[].Instances[].InstanceId" --output text)
[ -n "$IDS" ] && aws ec2 terminate-instances --region ap-northeast-2 --profile <profile> --instance-ids $IDS
```

**[주의] 3단계에서 `patch`만 하고 `delete`를 빠뜨리면 안 된다.** finalizer 제거는 "삭제를
막는 잠금을 푸는" 것일 뿐 삭제 요청이 아니다 — NodeClaim 오브젝트가 그대로 남아있는데
그 EC2만 종료되면, Karpenter는 이를 "노드가 비정상 소멸했다"로 해석해 **대체 노드를
새로 프로비저닝한다.**

4단계를 `kubectl get nodeclaims`의 `providerID`가 아니라 **AWS 태그 기준으로 조회**하는
이유도 같다. 재생성이 일어난 뒤에는 K8s 오브젝트 목록과 실제 인스턴스가 어긋나 있어,
K8s 기준으로 뽑으면 방금 뜬 인스턴스를 놓친다.

이 순서를 지키면 아래 polling 자체가 불필요하다. Karpenter 컨트롤러 생존 여부와도
무관해져 "컨트롤러가 먼저 죽어 finalizer가 안 풀리는" 데드락 위험까지 함께 사라진다.

> **WHY (2026-08-01 실측)**: `terminate-instances` + `finalizer patch`만 수행하고
> NodeClaim 삭제와 컨트롤러 정지를 빠뜨렸더니, 양 계정 합쳐 6대가 즉시 재생성됐다.
> 이후 컨트롤러만 `replicas=0`으로 내렸으나 monitoring에서는 ArgoCD가 되돌려(2-1-A 참조)
> 다시 3대가 떴다 — 총 3라운드에 걸쳐 9대를 종료했다. 재생성이 도는 동안
> `null_resource.karpenter_nodeclaims_drainer`(Step 6)가 끝나지 않아 destroy 전체가
> 대기 상태로 묶인다.

아래는 정석 경로(컨트롤러에게 drain을 맡기는 방식)로, 위 직접 종료를 쓰지 않을 때만 따른다.
이 Application들이 관리하는 NodePool/EC2NodeClass는 Karpenter 자신의 finalizer
(`karpenter.sh/termination`, `karpenter.k8s.aws/termination`)가 걸려있어, 연결된
NodeClaim(실제 EC2 노드)이 완전히 drain될 때까지 삭제가 안 끝난다 — **이때 karpenter
컨트롤러 자신은 아직 살아있어야 drain이 정상 진행된다.** 완전히 사라질 때까지 최대
3분 polling:

```bash
for i in $(seq 1 36); do
  count=$(kubectl get application -n argocd --no-headers 2>/dev/null | grep -c karpenter-resources)
  [ "$count" -eq 0 ] && break
  sleep 5
done
```

3분 초과 시 `kubectl get nodeclaims -A`로 확인 — `READY` 컬럼이 안 바뀌고 멈춰있으면
karpenter 컨트롤러가 이미 죽었거나 응답 없는 상태다. 이 경우 아래로 직접 정리한다
(WHY 참고 — 이게 바로 2026-07-21에 실제로 밟은 복구 경로다):

```bash
kubectl get node <stuck-node-name> -o jsonpath='{.spec.providerID}'   # arn 뒤 instance-id 추출
aws ec2 terminate-instances --region ap-northeast-2 --profile <profile> --instance-ids <instance-id>
kubectl patch nodeclaim <name> --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl delete node <stuck-node-name> --ignore-not-found
kubectl patch ec2nodeclass <name> --type=merge -p '{"metadata":{"finalizers":[]}}'
```

**[주의] `karpenter-resources` Application을 지우면 `argocd-application-controller` 자신이
스케줄 불가 상태에 빠질 수 있다 (2026-07-22 monitoring에서 실제 발생)**: 시스템 노드는
인스턴스 타입별 최대 pod 개수(t3.medium=17)가 고정돼 있고, `application-controller`
(및 `argocd-image-updater-controller`)가 평소 이 한도를 넘겨 Karpenter가 만든 여분
노드에서 돌고 있었다면, 그 NodePool을 지우는 순간 노드가 드레인되면서 두 파드가 갈 곳을
잃고 `Pending`(`0/1 nodes are available: 1 Too many pods`)에 빠진다.
`argocd-application-controller`가 죽으면 `resources-finalizer.argocd.argoproj.io`를
아무도 처리하지 못해 방금 지운 `karpenter-resources-*` Application 자체가 `Terminating`에
멈춘다 — 실제 NodeClaim/EC2NodeClass는 이미 다 지워졌는데(`kubectl get nodeclaims -A`,
`kubectl get ec2nodeclass`가 비어있음) Application 오브젝트만 남는 상태다. 확인 후
아래로 대응한다:

```bash
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o wide
# Pending이고 이벤트에 "Too many pods"가 있으면:
kubectl scale deployment argocd-image-updater-controller -n argocd --replicas=0   # teardown 중엔 불필요, 슬롯 1개 확보
# 그래도 application-controller가 안 뜨거나 이미 NodeClaim/EC2NodeClass가 확인상 비어있으면
# finalizer를 직접 제거한다(실제 AWS 리소스는 이미 정리됐으므로 안전):
kubectl patch application <stuck-app-name> -n argocd --type=merge -p '{"metadata":{"finalizers":[]}}'
```

**2-3. Ingress 삭제 — LBC가 아직 살아있는 상태에서 실행 (Step 3/4 내용이 여기로 통합됨)**

**[중요] Ingress만 훑으면 `Service type=LoadBalancer`가 만든 NLB를 통째로 놓친다.** 반드시
두 종류를 함께 조회한다 — OTel Gateway처럼 Service로 Internal NLB를 띄우는 컴포넌트가 있다:

```bash
kubectl get ingress -A -o json
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

LoadBalancer Service는 `EXTERNAL-IP`(LB DNS)를 기록한 뒤 그냥 `kubectl delete svc`하면
LBC가 NLB를 회수한다. Ingress와 동일하게 **LBC가 살아있는 동안** 처리해야 한다.

> **WHY (2026-07-31 실측)**: 이 절차가 Ingress 기준으로만 쓰여 있어 `otel-gateway-nlb`
> Service가 만든 NLB가 정리 대상에서 빠질 뻔했다. Route53도 같은 사각지대가 있다 —
> ExternalDNS가 Service에도 레코드를 만들며 TXT 소유자 값이
> `external-dns/resource=**service**/<ns>/<name>` 형태라 Ingress 목록만 보면 안 잡힌다
> (`otel-gateway.pyhtest.com` A+TXT+cname-TXT 3개가 이렇게 남아 Step 11에서야 발견됐다).

각 Ingress/LoadBalancer Service에 대해 **삭제 전에** 아래를 기록한다(삭제 후에는 조회 불가):
- `namespace`, `name`
- `status.loadBalancer.ingress[0].hostname` (ALB DNS 이름)
- `metadata.annotations."external-dns.alpha.kubernetes.io/hostname"` (Route53 레코드 이름)
- **annotation이 비어있으면 `spec.rules[].host`도 확인한다** — ExternalDNS는 이 annotation
  없이도 Ingress `spec.rules[].host`만으로 레코드를 만들 수 있다(2026-07-30 monitoring
  teardown 실제 발생: grafana Ingress에 annotation이 없어 Route53 대상에서 빠졌고, Step 11
  zone 전체 재검증에서야 고아 A+TXT+cname-TXT로 발견됐다). annotation·host 필드 둘 다
  비어있을 때만 "이 Ingress는 Route53 관리 대상 아님"으로 판단한다.

기록 후 각각 삭제한다:

```bash
kubectl delete ingress <name> -n <namespace>
```

**2-4. ALB 정리 완료 대기 (LBC가 처리할 시간을 준다)**

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --profile <profile> \
  --query "LoadBalancers[?DNSName=='<기록한 ALB DNS 이름>']"
```

2-3에서 기록한 모든 ALB가 빈 결과(`[]`)가 될 때까지 최대 3분 polling한다. 이 시점엔
LBC(`aws-load-balancer-controller` Application)가 아직 살아있으므로 정상적으로 ALB를
정리한다 — **3분이 지나도 안 사라지면 LBC 파드가 이미 죽었을 가능성이 높다**
(`kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`로
확인). 이 경우 Ingress의 finalizer(`ingress.k8s.aws/resources`)가 영구히 안 풀리므로
아래로 직접 정리한다(2026-07-21 monitoring에서 실제로 겪은 복구 경로):

```bash
# target group ARN 확보(ALB 삭제 후엔 조회 불가하므로 먼저)
aws elbv2 describe-target-groups --region ap-northeast-2 --profile <profile> --load-balancer-arn <lb-arn>
# ALB의 SecurityGroups 필드도 미리 확보(elbv2.k8s.aws/cluster 태그로 LBC 소유 확인 후 삭제 대상에 포함)
aws elbv2 delete-load-balancer --region ap-northeast-2 --profile <profile> --load-balancer-arn <lb-arn>
kubectl patch ingress <name> -n <namespace> --type=merge -p '{"metadata":{"finalizers":[]}}'
# ALB가 완전히 사라진 뒤(polling)
aws elbv2 delete-target-group --region ap-northeast-2 --profile <profile> --target-group-arn <tg-arn>
aws ec2 delete-security-group --region ap-northeast-2 --profile <profile> --group-id <sg-id>
```

**2-5. (선택, 기본 생략) 나머지 전부 (LBC/karpenter 컨트롤러 포함)**

**기본적으로 실행하지 않는다** — Step 2 도입부 참고: 2-2·2-3·2-4로 AWS 리소스 위험은
이미 없앴고, 나머지 Application/ApplicationSet은 Step 8(EKS destroy)이 지우면 그만이다.
"ArgoCD를 계속 깨끗하게 쓰고 싶다"거나 "클러스터를 지우지 않고 addon만 다시 원복하고
싶다" 같은 예외적 상황에서만 이 단계를 명시적으로 실행한다 — 그 경우에도 Ingress/ALB
정리(2-3, 2-4)와 karpenter-resources(2-2)가 완전히 끝난 뒤에만 진행해야 한다(그래야
controller Application(LBC, karpenter 등)을 지워도 더 이상 정리할 게 남아있지 않아
안전하다):

```bash
kubectl delete application --all -n argocd --ignore-not-found
kubectl delete applicationset --all -n argocd --ignore-not-found
```

```bash
for i in $(seq 1 24); do
  count=$(kubectl get application -n argocd --no-headers 2>/dev/null | wc -l)
  [ "$count" -eq 0 ] && break
  sleep 5
done
```

> **WHY (2026-07-21, `--all`을 처음부터 한꺼번에 쓰면 안 되는 이유 — 실제 데드락 2건 재현)**:
> 처음엔 Application/ApplicationSet을 순서 구분 없이 `--all`로 한 번에 지우고, Ingress
> 삭제는 그 이후(옛 Step 3)에 진행했다. 두 가지 데드락이 실제로 발생했다:
> (1) `root-app-addons`(ApplicationSet)가 아직 살아있는 찰나에 그 Application이 삭제되자,
> ApplicationSet 컨트롤러가 즉시 재생성 → devops-manifest 디렉터리 재동기화 → 이미 지운
> 나머지 17개 ApplicationSet이 전부 부활했다(`preserveResourcesOnDeletion: true`는
> "ApplicationSet 자신이 지워질 때 하위 리소스를 보존"하는 것이지 이 재생성 경합을 막지
> 못한다). (2) `karpenter`/`aws-load-balancer-controller`(컨트롤러 Helm release)
> Application과 `karpenter-resources`/Ingress가 순서 보장 없이 동시에 처리되면서,
> 컨트롤러가 먼저 죽어버리면 NodePool·Ingress 각각의 자체 finalizer(`karpenter.sh/
> termination`, `ingress.k8s.aws/resources`)가 기다리는 정리 작업을 아무도 처리 못 해
> 영구 데드락에 빠졌다 — monitoring/dev의 Karpenter, monitoring의 LBC 전부 이걸로 걸려
> EC2 인스턴스/ALB를 직접 `terminate-instances`/`delete-load-balancer`하고 finalizer를
> 강제로 제거해야 했다. 근본 원인은 같다: `--all`은 리소스 간 의존 순서를 전혀 모른다.
> Terraform의 `null_resource.karpenter_nodeclaims_drainer`가 원래 이 문제를 안 겪는
> 이유는 컨트롤러 IAM Role을 지우기 *전에* drain을 먼저 실행하도록 `depends_on`으로
> 순서를 강제하기 때문이다 — kubectl 직접 삭제에는 그런 보장이 없으므로, "실제 AWS
> 리소스를 관리하는 addon(LBC/Karpenter)의 리소스"는 그 컨트롤러가 살아있는 동안 먼저
> 정리하고, 컨트롤러 자신은 맨 마지막(2-5)에 지우는 순서를 수동으로 강제해야 한다.

> **WHY (2026-07-21, root-app-addons가 Terraform 소유가 되면서 재검토)**: 이 Step은 원래
> "Application/ApplicationSet은 클러스터 destroy 시 etcd와 함께 자동으로 사라지니 손댈
> 필요 없다"는 이유로 비활성화돼 있었다. 이 판단은 `root-app-addons`가 순수 K8s 리소스일
> 때는 맞았지만, 이제 `root-app-addons`가 `helm_release`로 Terraform state에 들어오면서
> Step 6(`eks-addons destroy`)이 이걸 `helm uninstall`로 지우는 시점과, Step 8(EKS
> destroy)이 클러스터 자체를 지우는 시점 사이에 **간극**이 생겼다 — 그 사이에도 ArgoCD
> 자신은 여전히 살아있고 나머지 17개 addon ApplicationSet은 root-app-addons와 무관하게
> 독립적으로 계속 selfHeal을 수행한다. 특히 LBC가 관리하는 ALB는 Ingress 객체가 실제로
> 삭제된 채 유지돼야만 정리되는데, ArgoCD가 그 삭제를 되돌리면 Step 4의 "ALB가 사라졌는지"
> 확인이 일시적 상태만 보고 통과해버릴 위험이 있다 — 그 직후 ArgoCD가 Ingress를 재생성하면
> 새로 뜬 ALB가 아무도 모르는 채 고아로 남는다. `root-app-addons` 자신은
> `preserveResourcesOnDeletion: true`가 걸려있어 그것만 지워서는 나머지 17개
> ApplicationSet의 selfHeal이 멈추지 않으므로(각자 독립적으로 계속 조정), `--all`로 전부
> 지워 ArgoCD의 능동적 조정 자체를 끊는 것이 유일하게 확실한 방법이다. 이 환경은 dev/prod
> 구분 없이 여러 서비스가 namespace로만 분리돼 한 클러스터에 배포될 수 있으므로
> (`gateway-dev` Ingress 관련 2026-07-04 사고 참고, 아래), Application이 여러 개 있을 수
> 있다는 전제로 `--all`을 쓴다.
>
> **WHY (이 단계가 애초에 만들어진 이유, 2026-07-04)**: monitoring teardown에서
> `gateway-dev` Ingress를 Step 3(당시 Step 2) 절차대로 삭제했지만, 그 Ingress는 ArgoCD
> Application `gateway-dev`가 계속 소유·조정하고 있었다. 클러스터를 완전히 destroy한
> 뒤에도 그 ALB(및 연결된 대상 그룹·보안 그룹 2개)가 고아로 남아 수동 정리가 필요했다 —
> 근본 원인은 "Ingress를 지우는 시점에 ArgoCD가 여전히 그 리소스를 관리 중이었다"는
> 것이었다.

Step 11의 zone 전체 재검증(모든 ALB·Route53 레코드를 스캔해 대응 리소스가 없는 고아를
찾아 정리)은 이 Step으로 위험이 줄어도 여전히 **반드시** 실행한다 — 최종 안전망이다.

### Step 3/4 (통합됨, 2026-07-21): Ingress/ALB 정리는 Step 2-3·2-4로 이동

**이 두 Step은 더 이상 별도로 실행하지 않는다.** LBC(Ingress를 처리하는 컨트롤러)가
아직 살아있는 동안 정리해야 해서, Step 2(ArgoCD 조정 해제)의 중간 단계로 옮겨졌다 —
Step 2-3(Ingress 삭제), Step 2-4(ALB 정리 대기) 참고. 이 자리는 번호 유지를 위한
자리표시자다. Step 5로 바로 진행한다.

### Step 5: Route53 레코드 수동 삭제 — 잔여 리소스 관리 핵심

> **[속도] 이 Step은 Step 8(EKS destroy)과 병렬로 돌린다.** Route53은 클러스터·Terraform과
> 아무 의존이 없다(ExternalDNS는 이미 없거나 곧 사라지고, `upsert-only`라 어차피 레코드를
> 건드리지 않는다). Step 2-3에서 호스트명을 기록해뒀다면 **Step 6/8을 백그라운드로 시작한
> 뒤 그 대기 시간에 이 Step과 EBS 직접 삭제를 처리**한다 — 순차로 하면 그만큼 그대로
> 늘어난다. 아래 서술 위치는 논리적 순서일 뿐 실행 순서가 아니다.

`modules/eks-addons/1.0.0`의 ExternalDNS helm_release는 `policy`를 오버라이드하지 않아
차트 기본값(`upsert-only`, 생성·갱신만 하고 삭제는 절대 하지 않음)을 그대로 쓴다.
**즉 Ingress를 지워도 ExternalDNS는 Route53 레코드를 스스로 지우지 않는다** — 이는 예외
상황이 아니라 이 프로젝트의 정상 동작이다 (2026-07-02 monitoring teardown에서
`kubectl logs`로 확인: 삭제 후에도 계속 `All records are already up to date`만 출력).

Step 2-3에서 기록한 `external-dns.alpha.kubernetes.io/hostname` 값이 있는 Ingress마다,
`{root}/eks-addons/locals.tf`에서 `external_dns_route53_zone_arns`를 Grep해 zone ID를 추출한 뒤
현재 레코드를 조회한다 (workload 계정이 zone을 소유하므로 profile은 항상 `terraform-workload`).
**`<hostname>.`뿐 아니라 `cname-<hostname>.`도 함께 조회한다** (아래 WHY 참고):

```bash
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
  --query "ResourceRecordSets[?Name=='<hostname>.' || Name=='cname-<hostname>.']"
```

**삭제 전 ExternalDNS 소유 레코드인지 TXT 값으로 확인한다**: 위 결과 중 `Type=='TXT'`인
레코드의 `ResourceRecords[0].Value`에 `heritage=external-dns`가 포함되어 있는지 확인한다.
포함되어 있으면 사람이 수동으로 만든 레코드가 아니라 ExternalDNS가 생성·관리하는
레코드라는 확정적 증거이므로 안전하게 삭제 대상에 포함한다. 값 안의
`external-dns/resource=ingress/<namespace>/<name>` 부분이 Step 2-3에서 기록한 삭제 대상
Ingress와 일치하는지도 함께 확인하면 다른 Ingress의 레코드를 잘못 지우는 실수를 방지할 수
있다 (`external-dns/owner=<id>`는 같은 zone을 여러 ExternalDNS 인스턴스가 공유할 때 어느
인스턴스 소유인지 구분하는 값이다). `heritage=external-dns` 마커가 없는 레코드는 이
자동 삭제 대상에서 제외하고 사용자에게 별도로 보고한다.

결과가 있으면(거의 항상 있음) 레코드 내용을 사용자에게 보여주고, 확인을 기다리지 않고
바로 조회된 레코드 전부(보통 A + TXT + cname- TXT 3개)를 하나의 change-batch로 DELETE한다
(teardown 자체가 이미 Step 0에서 삭제 대상으로 안내·승인된 작업이므로 레코드 단위로
다시 확인받지 않는다):

**[필수] 삭제 대상 필터는 `index()` 정확 일치로 짠다 — `inside`/`contains`/`test`를 쓰지
않는다.** 여러 호스트를 한 번에 지울 때 아래 스니펫을 그대로 쓴다(검증됨, 2026-08-09):

```bash
SCRATCH="<스크래치패드 경로>"   # AWS CLI file://은 한글 경로를 못 읽는다
HOSTS='["argocd.pyhtest.com.","cname-argocd.pyhtest.com.","grafana.pyhtest.com.","cname-grafana.pyhtest.com."]'
aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload --output json \
  | jq --argjson t "$HOSTS" '{Changes: [.ResourceRecordSets[]
      | select(.Name as $n | $t | index($n))
      | {Action:"DELETE", ResourceRecordSet:.}]}' > "$SCRATCH/r53-del.json"

# 제출 전 반드시 눈으로 확인 — 개수와 목록이 의도와 일치해야 한다
jq -r '.Changes | length, (.[] | .ResourceRecordSet.Name + " " + .ResourceRecordSet.Type)' "$SCRATCH/r53-del.json"

aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
  --change-batch "file://$SCRATCH/r53-del.json" --query "ChangeInfo.Status" --output text
```

> **WHY (2026-08-09 실측)**: 같은 목적으로 `[.Name] | inside($t)`를 썼다가 배치가 통째로
> 거부됐다 — `A HostedZone must contain at least one NS record for the zone itself.,
> A HostedZone must contain exactly one SOA record.` **jq의 `inside`/`contains`는 배열
> 원소가 문자열이면 부분 문자열 매칭을 한다.** zone apex인 `pyhtest.com.`(NS·SOA)이
> `api-develop.pyhtest.com.`의 부분 문자열이라 12건 대신 14건이 잡혔다. Route53
> ChangeBatch는 원자적이라 **부분 삭제 위험은 없었지만** 왕복 2회가 낭비됐다.
> `test()` 정규식도 백슬래시가 셸·jq를 거치며 깨져 컴파일 에러가 났다(`Invalid escape`) —
> 정확 일치 `index()`가 이 환경에서 유일하게 한 번에 통과한 방식이다.

호스트가 하나뿐이면 아래처럼 인라인으로 써도 된다(각 레코드 JSON은 위
`list-resource-record-sets` 결과에서 그대로 사용한다):

```bash
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
  --change-batch '{
    "Changes": [
      {"Action": "DELETE", "ResourceRecordSet": <A 레코드 전체 JSON>},
      {"Action": "DELETE", "ResourceRecordSet": <hostname TXT 레코드 전체 JSON>},
      {"Action": "DELETE", "ResourceRecordSet": <cname-hostname TXT 레코드 전체 JSON>}
    ]
  }'
```

> **WHY (수동 삭제 자체)**: `policy=sync`로 바꾸면 ExternalDNS가 스스로 삭제하게 할 수 있지만,
> 이는 실습 편의를 위해 운영 안전장치(오작동 시 의도치 않은 레코드 삭제 방지)를 낮추는
> 트레이드오프다. 현재는 수동 삭제로 안전장치를 유지한다. 정책을 바꾸려면
> `modules/eks-addons/1.0.0`의 external_dns helm_release 설정 변경이 필요하며
> develop/production에도 영향을 준다.
>
> **WHY (`cname-<hostname>` TXT도 함께 삭제)**: ExternalDNS는 A 레코드 소유권 추적용 TXT
> (`<hostname>`) 외에, ALIAS(A) 레코드가 가리키는 대상(ALB CNAME)의 소유권을 추적하는 보조 TXT
> (`cname-<hostname>`)도 함께 만든다. 2026-07-02 monitoring 재생성 검증 중 이 레코드를
> teardown에서 빠뜨렸더니, 다음 `/env-provision`에서 ExternalDNS가 A+TXT+cname-TXT 3개를
> 하나의 Route53 change batch로 묶어 제출하다가 `cname-<hostname>` TXT가 이미 존재한다는
> 이유로 **배치 전체가 실패**했다 (Route53 ChangeBatch는 원자적이라 하나만 걸려도 A 레코드
> 생성까지 함께 막힌다). Ingress 하나에 A 1개 + TXT 2개가 세트로 생긴다는 점을 항상 함께
> 고려해야 한다.

### Step 6: eks-addons destroy

```bash
cd {root}/eks-addons && terraform destroy -auto-approve
```

**`Timed out when waiting for resource ... to be deleted` 에러 시** (finalizer 잔존):

```bash
kubectl get <kind> <name> -n <namespace> -o jsonpath='{.metadata.finalizers}'
kubectl patch <kind> <name> -n <namespace> --type=merge -p '{"metadata":{"finalizers":[]}}'
```

제거 후 destroy를 재시도한다. 그 외 에러는 사용자에게 보고 후 중단한다.

> **참고 (2026-07-21 — root-app-addons는 이미 Step 2에서 지워진 상태로 도달함)**:
> monitoring의 `helm_release.bootstrap["addons"]`(root-app-addons)는 Step 2에서
> `kubectl delete application/applicationset --all`로 이미 삭제됐다. Terraform은 여전히
> 이 리소스를 state에 갖고 있으므로 이 destroy가 `helm uninstall`을 시도하는데, 대상이
> 이미 없어 보통 조용히 성공(no-op)한다 — 만약 `release: not found` 류 에러로 destroy가
> 막히면 `terraform state rm 'module.eks_addons.module.gitops_bridge_bootstrap.helm_release.bootstrap["addons"]'`로
> state에서만 제거하고 계속 진행한다(K8s 쪽엔 이미 없으므로 안전).

> **참고 (2026-07-18 갱신 — external-secrets webhook 사전 제거 단계 제거됨)**: 예전에는 이
> Step 앞에 `externalsecret-validate`/`secretstore-validate` ValidatingWebhookConfiguration을
> 미리 지우는 단계가 있었다 — Karpenter 노드 조기 drain으로 external-secrets-webhook 파드가
> 먼저 사라지면, Terraform이 소유하던 ExternalSecret/ClusterSecretStore(`aws_parameterstore_secret_store`,
> `argocd_image_updater_git_creds` 등) 삭제가 webhook 호출 실패로 멈추는 문제 때문이었다.
> Phase 6-4 GitOps Bridge 이관으로 이 리소스들이 전부 devops-manifest(ArgoCD Application)로
> 옮겨가면서, monitoring/develop/production 어디에도 Terraform이 직접 소유하는 ExternalSecret/
> ClusterSecretStore/SecretStore가 더 이상 없다 — 이 문제 자체가 발생할 수 없어졌으므로
> 단계를 완전히 제거했다.

### Step 7: eks-addons destroy 사후 검증 — Terraform state 및 AWS API 이중 확인

Step 6이 `Destroy complete!`로 끝났다는 출력만으로 완료 처리하지 않는다. GitOps Bridge
이관 여부(`modules/eks-addons/1.0.0` vs `2.0.0` 이상)와 무관하게, LBC/Karpenter/
ExternalDNS/ExternalSecrets의 IAM Role·Policy와 Karpenter의 SQS 인터럽션 큐·EventBridge
Rule은 **항상** 이 root(`eks-addons`)의 Terraform state가 관리해왔다 — GitOps Bridge는
이 addon들의 Helm 설치 주체를 Terraform에서 ArgoCD로 옮겼을 뿐, IAM/AWS 리소스는 이관
여부와 무관하게 계속 Terraform 소관이다. 따라서 이 검증은 addon별 표를 따로 유지할
필요 없이 아래 두 방식으로 충분하다:

**1. Terraform state 자체 확인 (구조적 검증 — addon이 늘어나도 자동으로 커버)**

```bash
cd {root}/eks-addons && terraform state list
```

`terraform destroy`가 성공했다면 이 출력은 **반드시 비어있어야 한다**. 무엇이든 남아있으면
Step 6이 일부만 destroy된 것이므로, 남은 리소스 주소를 사용자에게 보고하고 원인을 확인한다
(재시도로 넘어가지 않는다 — 부분 destroy 상태에서 재시도하면 의도치 않은 순서로 나머지가
지워질 수 있다).

**2. AWS API로 실제 리소스 소멸 재확인 (state가 비어도 전파 지연 가능성 대비)**

```bash
aws iam list-roles --profile <profile> --query "Roles[?contains(RoleName, '<cluster_name>')].RoleName" --output text
aws sqs list-queues --region ap-northeast-2 --profile <profile> --queue-name-prefix <cluster_name>
aws events list-rules --region ap-northeast-2 --profile <profile> --name-prefix <cluster_name>
```

첫 번째 명령 결과에 `lbc`/`load-balancer`, `karpenter`, `external-dns`, `external-secrets`
문자열이 포함된 role이 남아있거나, 두 번째·세 번째 명령 결과가 비어있지 않으면 AWS 쪽
전파가 아직 안 끝난 것이니 최대 2분 polling 후 재확인한다. 그래도 남아있으면 Step 6 destroy
결과와 모순되는 것이므로 재시도 없이 사용자에게 보고한다.

> **WHY (2026-07-18 GitOps Bridge 이관 후 도입)**: monitoring이 `modules/eks-addons/2.0.0`로
> 이관되며 Terraform이 더 이상 addon의 Helm release를 직접 만들지 않게 됐다 — Step 6의
> `terraform destroy` 출력만 보고 "addon이 다 지워졌다"고 판단하면, 실제로는 Terraform이
> 애초에 관리하지 않는(ArgoCD가 설치한) 부분과 Terraform이 여전히 관리하는 IAM/AWS 부분을
> 혼동하기 쉽다. addon 이름별로 "이건 Terraform 관리, 이건 ArgoCD 관리"를 표로 유지하는
> 방식은 addon이 추가로 이관될 때마다 갱신을 깜빡할 위험이 있으므로, 대신 `terraform state
> list`가 비어있는지를 1차 기준으로 삼는다 — state는 코드가 실제로 무엇을 관리하는지를
> 그 자체로 보여주므로 이관 목록이 바뀌어도 이 검증 절차 자체는 고칠 필요가 없다. AWS API
> 조회는 state가 비어도 IAM/SQS/EventBridge의 실제 삭제 전파가 늦어질 수 있는 경우를 잡기
> 위한 보조 확인이다.

### Step 8: EKS 클러스터 destroy — VPC NAT Gateway 비활성화와 병렬 시작

```bash
cd {root}/eks && terraform destroy -auto-approve
```

이 destroy를 시작하는 즉시(완료를 기다리지 않고) **같은 환경의 Step 10 NAT Gateway
비활성화는 병렬로 시작한다.** eks-addons가 이미 Step 6에서 삭제되어 클러스터 안에
아웃바운드가 필요한 워크로드가 남아있지 않으므로, EKS 클러스터 destroy 자체(컨트롤
플레인·노드그룹·SG 삭제는 AWS API 호출이지 고객 VPC 경유 아웃바운드가 아니다)는 NAT
Gateway 유무와 무관하게 안전하게 동시 진행할 수 있다 (2026-07-04 확인 — provision 쪽
Step 1/2 병렬화와 같은 근거).

> **[순서 제약] monitoring의 NAT Gateway는 spoke(develop/production)의 EKS destroy가
> 전부 끝난 뒤에 지운다 (2026-08-01 실측).** spoke의 `eks` root는 Hub→spoke API 접근용
> 출발 IP를 얻기 위해 monitoring NAT를 **data source로 조회**한다
> (`project/environments/*/ap-northeast-2/shared/eks/data.tf`의
> `data.aws_nat_gateway.monitoring` → `locals.tf`의 `public_access_cidrs`). data source는
> destroy 시에도 plan 단계에서 평가되므로, monitoring NAT가 먼저 사라지면 spoke의
> `terraform destroy`가 실행 전에 통째로 실패한다:
>
> ```
> Error: no matching EC2 NAT Gateway found
>   on data.tf line 36, in data "aws_nat_gateway" "monitoring":
> ```
>
> **따라서 여러 환경을 함께 지울 때 NAT 병렬화 범위는 "환경 내부"로 한정한다** — spoke의
> EKS destroy와 spoke의 NAT 비활성화는 병렬, monitoring NAT는 모든 spoke EKS destroy가
> `Destroy complete!`를 찍은 뒤에 시작한다. monitoring EKS destroy 자체는 monitoring NAT와
> 병렬로 돌려도 무방하다.
>
> 이미 monitoring NAT를 먼저 지워 spoke destroy가 막혔다면, NAT를 되살리지 말고 spoke
> `eks/data.tf`의 해당 data source 블록과 `locals.tf`의 참조를 임시 주석 처리한 뒤
> (`public_access_cidrs = [var.operator_ip_cidr]`) destroy하고, **완료 후 반드시 원복한다**
> — destroy에는 이 값이 아무 영향도 주지 않는다. 원복 누락을 막기 위해 편집 전
> 두 파일을 `$RUN_DIR`에 백업해두고, Step 11에서 `git status`로 두 파일이 목록에 없는지
> 확인한다.

**`deleting Security Group ...: DependencyViolation: resource ... has a dependent
object` 에러 시** (VPC CNI가 만든 secondary ENI 잔존 — 2026-07-04 monitoring teardown
실제 발생, 배경은 `docs/environment-teardown.md` "Karpenter 노드 강제 종료로 인한 VPC CNI
ENI 잔존" 참조):

```bash
aws ec2 describe-network-interfaces --region ap-northeast-2 --profile <profile> \
  --filters "Name=group-id,Values=<막힌 security-group-id>" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description}"
```

`Description`이 `aws-K8S-i-<instance-id>` 형태이고 `Status`가 `available`이면 해당 ENI를
직접 삭제한 뒤 `terraform destroy`를 재시도한다:

```bash
aws ec2 delete-network-interface --region ap-northeast-2 --profile <profile> \
  --network-interface-id <eni-id>
```

그 외 에러는 재시도하지 말고 사용자에게 보고 후 중단한다.

### Step 9: kubeconfig 정리 — 삭제된 클러스터의 잔여 항목 제거

Step 1에서 클러스터에 연결하지 못해 Step 2~5를 건너뛴 경우(이미 삭제됐거나 최초 생성 전)는
이 단계도 조용히 스킵한다. 그 외에는 `~/.kube/config`에 남아있는 context/cluster/user
항목을 제거한다:

```bash
context_name=<cluster_name>
if kubectl config get-contexts "$context_name" >/dev/null 2>&1; then
  cluster_ref=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context_name')].context.cluster}")
  user_ref=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$context_name')].context.user}")
  kubectl config delete-context "$context_name"
  [ -n "$cluster_ref" ] && kubectl config delete-cluster "$cluster_ref"
  [ -n "$user_ref" ] && kubectl config delete-user "$user_ref"
fi
```

> **WHY**: EKS 클러스터를 destroy해도 Step 1에서 `aws eks update-kubeconfig --alias
> <cluster_name>`로 추가된 kubeconfig 항목은 자동으로 지워지지 않는다. 방치하면
> `kubectl config get-contexts`에 존재하지 않는 클러스터를 가리키는 context가 재생성마다
> 계속 쌓인다. `delete-context`는 context 항목만 지우므로, cluster/user 항목은 실제
> 등록된 이름(별칭이 아니라 ARN 등으로 등록될 수 있음)을 먼저 조회한 뒤 각각 지워야
> 잔여 항목 없이 완전히 제거된다.

### Step 10: VPC NAT Gateway 비활성화 (Step 8과 병렬 실행 — 이미 시작했다면 완료만 확인)

`{root}/vpc/locals.tf`를 Read하여 `enable_nat_gateway`가 이미 `false`면 스킵.
`true`면 Edit로 `false`로 변경 후, **Step 8의 EKS destroy 완료를 기다리지 말고** 실행한다:

```bash
cd {root}/vpc && terraform apply -auto-approve
```

**`production`인 경우**, 위 명령 앞에 `ALLOW_PRODUCTION_TEARDOWN_APPLY=1`
마커를 붙여 실행한다 (`docs/environment-teardown.md` 참고, 훅이 이 명령 1회에
한해서만 통과시킨다):

```bash
cd {root}/vpc && ALLOW_PRODUCTION_TEARDOWN_APPLY=1 terraform apply -auto-approve
```

**VPC 자체, 서브넷, 파라미터 스토어 등 비용이 없는 리소스는 삭제하지 않는다** — plan에
NAT Gateway/EIP/private route 외의 destroy가 나타나면 즉시 중단하고 사용자에게 확인받는다.

Step 11로 넘어가기 전에 이 apply와 Step 8의 EKS destroy가 **둘 다** 완료됐는지 확인한다.

### Step 11: 완료 안내 및 잔여 비용 리소스 최종 확인

**Route53 zone 전체 고아 레코드 재검증** — 완료 보고 전에 반드시 수행한다. Step 5는 "이번
세션에서 `kubectl get ingress -A`로 조회된 Ingress"만 대상으로 하므로, 과거 세션에서 빠뜨린
레코드나 이 프로젝트처럼 여러 서비스가 namespace로만 분리되어 한 클러스터에 배포되는 구조에서
발생하는 잔여물은 잡아내지 못한다. zone 전체를 기계적으로 훑어 "레코드는 있는데 가리키는
ALB가 이미 없는" 고아 상태를 찾는다:

```bash
zone_id=<Step 5에서 사용한 zone-id>
aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --profile terraform-workload \
  --query "ResourceRecordSets[?Type=='TXT']" --output json
```

결과에 남은 각 TXT 레코드에 대해:
1. `Value`에 `heritage=external-dns`가 없으면 스킵한다 (사람이 만든 레코드일 수 있으므로
   자동 삭제 대상에서 제외하고 이 레코드 이름만 사용자에게 보고).
2. `cname-` 접두사가 없는 이름(`<hostname>`)이면, 대응하는 A 레코드의
   `AliasTarget.DNSName`(ALB DNS 이름)을 조회한다.
3. 그 ALB가 실제로 존재하는지 확인한다 (환경별 profile로):

   ```bash
   aws elbv2 describe-load-balancers --region ap-northeast-2 --profile <profile> \
     --query "LoadBalancers[?DNSName=='<alb-dns>']"
   ```

4. 빈 결과(`[]`)면 — ALB는 이미 삭제됐는데 레코드만 남은 고아 상태 — Step 5와 동일한 방식
   (A + 해당 TXT + `cname-` TXT 3개를 하나의 change-batch로) 삭제한다. **삭제 대상 필터도
   Step 5의 `index()` 정확 일치 스니펫을 그대로 쓴다** — 이 Step은 zone apex(NS·SOA)가
   포함된 전체 목록을 다루므로 부분 문자열 매칭 시 배치 전체가 거부된다.
5. ALB가 실제로 존재하면(다른 서비스·환경이 현재 사용 중인 레코드) 삭제하지 않고
   사용자에게만 보고한다.

> **WHY**: 2026-07-06 monitoring teardown에서 이번 세션의 Ingress 목록(Step 3)만 정리한 뒤
> 완료를 보고했으나, 사용자가 재확인을 요청해 zone 전체를 훑어보니 과거 세션의
> `eks-practice-dev/gateway-dev` Ingress가 남긴 A+TXT+cname-TXT 레코드가 대응 ALB 없이 고아로
> 남아있었다(해당 ALB는 이미 삭제된 상태). Step 3~5는 "이번 세션에 존재했던 Ingress"만
> 추적하는 구조적 한계가 있으므로, 완료 보고 전 zone 전체 재검증을 teardown 절차의 필수
> 단계로 승격한다.

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --profile <profile>
aws ec2 describe-nat-gateways --region ap-northeast-2 --profile <profile> \
  --filter "Name=state,Values=available,pending"
# 고아 EBS 볼륨 확인 — LGTM 등 스테이트풀 워크로드의 PVC가 남긴 available(미연결) 볼륨.
# 2-1-B에서 정리했어도 최종 안전망으로 재확인한다(EBS CSI가 만든 볼륨은 이 태그를 갖는다).
aws ec2 describe-volumes --region ap-northeast-2 --profile <profile> \
  --filters "Name=status,Values=available" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
  --query "Volumes[].VolumeId" --output text
```

세 명령 결과가 모두 비어있으면 완료 메시지를 출력한다 (고아 EBS 볼륨이 있으면
`aws ec2 delete-volume --volume-id <id>`로 직접 삭제 후 재확인):

**임시 편집 원복 확인**: Step 8의 순서 제약 때문에 spoke `eks/data.tf`·`locals.tf`를
주석 처리했다면, `git status --short`에 두 파일이 나타나지 않는지 확인한다(나타나면
`$RUN_DIR` 백업본으로 원복). NAT 토글(`vpc/locals.tf`)만 변경 목록에 남아있는 것이 정상이다.

**소요 시간 출력**: `$RUN_DIR/timing.log`를 그대로 보여주고 자동화 구간 합계를 덧붙인다
(공통 처리 "실행 로그 위치와 소요 시간 측정" 참조). `[대기]` 항목은 합계에서 제외하되
표에는 남겨 "사람이 기다린 시간"과 "절차가 쓴 시간"을 구분해 보여준다.

```
[완료] <환경> 비용 발생 리소스 삭제 완료
- ArgoCD Application/ApplicationSet: 삭제 완료
- eks-addons: 삭제 완료 (Terraform state 비어있음 + IAM/SQS/EventBridge AWS API 확인 완료)
- EKS 클러스터: 삭제 완료
- kubeconfig: context/cluster/user 정리 완료
- NAT Gateway: 비활성화
- VPC/서브넷/파라미터 스토어: 유지 (비용 없음)

[소요 시간]  (로그: <RUN_DIR>)
Step 2 LB/Karpenter/Route53           492s
Step 6 eks-addons destroy (dev)       270s
Step 6 eks-addons destroy (mon)       365s
Step 8 EKS destroy (병렬)             700s
[대기] SSO 재로그인                    185s
──────────────────────────────────────────
총 소요(자동화 구간 합)               1827s

재개 시 /env-provision <환경> 실행.
```

**`describe-load-balancers`에 잔여 ALB가 남아있는 경우** (클러스터가 이미 삭제되어 LBC가
없으므로 terraform destroy로는 정리되지 않음 — 2026-07-04 monitoring teardown 실제 발생 사례,
Step 2 WHY 참고): 수동으로 정리한다.

```bash
LB_ARN=<잔여 ALB의 LoadBalancerArn>

# 1. 연결된 대상 그룹 확인 (ALB 삭제 후에도 남으므로 미리 ARN 확보)
aws elbv2 describe-target-groups --region ap-northeast-2 --profile <profile> --load-balancer-arn "$LB_ARN"

# 2. 연결된 보안 그룹 확인 (ALB의 SecurityGroups 필드 — LBC가 자동 생성한 것인지
#    elbv2.k8s.aws/cluster 태그로 확인. 다른 리소스가 공유하는 SG면 삭제하지 않는다)
aws ec2 describe-security-groups --region ap-northeast-2 --profile <profile> \
  --group-ids <sg-id-1> <sg-id-2> --query "SecurityGroups[].{GroupId:GroupId,Description:Description,Tags:Tags}"

# 3. ALB 삭제 → ENI 해제 대기(수 분) → 대상 그룹 삭제 → 보안 그룹 삭제 (이 순서 필수:
#    ALB가 SG를 참조하는 동안에는 SG 삭제가 실패한다)
aws elbv2 delete-load-balancer --region ap-northeast-2 --profile <profile> --load-balancer-arn "$LB_ARN"
# describe-load-balancers로 완전히 사라질 때까지 polling 후:
aws elbv2 delete-target-group --region ap-northeast-2 --profile <profile> --target-group-arn <위에서 확인한 ARN>
aws ec2 delete-security-group --region ap-northeast-2 --profile <profile> --group-id <sg-id>
```

정리 후 이 Step의 두 확인 명령을 재실행해 빈 결과인지 다시 검증한다.
