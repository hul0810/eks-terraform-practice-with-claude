---
name: env-teardown
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(eks-addons, EKS 클러스터, VPC NAT Gateway)를
  역순으로 삭제한다. terraform destroy만으로는 정리되지 않는 잔여 리소스
  (ArgoCD Application/ApplicationSet가 재조정 중인 Ingress·ALB, workload 계정 Route53에
  ExternalDNS가 만든 레코드, karpenter 노드 조기 drain으로 발생하는 external-secrets 웹훅 교착과
  VPC CNI secondary ENI 잔존, 삭제된 클러스터를 가리키는 ~/.kube/config 잔여 context/cluster/user
  항목)까지 함께 관리한다.
  VPC 자체·서브넷·파라미터 스토어 등 비용이 없는 리소스는 삭제하지 않는다. 3개 환경 모두
  실습용이므로 production도 대상이다.
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

> **참고**: `production`은 `.claude/hooks/block-production-apply.sh`(PreToolUse 훅)가
> `environments/production` 경로의 `terraform apply`를 기본적으로 차단한다
> (`terraform destroy`는 정규식 대상이 아니므로 차단되지 않는다). 즉 Step 7~8의
> `terraform destroy`는 그대로 진행되지만, Step 10의 NAT Gateway 비활성화(`terraform apply`)는
> 훅에 막힌다. production teardown도 실습 예외 대상이므로, Step 10에서는 명령 앞에
> `ALLOW_PRODUCTION_TEARDOWN_APPLY=1` 마커를 붙여 실행한다 (`docs/environment-teardown.md`
> "production teardown — 보호 원칙과 실습 예외" 참고). 이 마커는 해당 명령 1회에만 적용되며,
> teardown 목적 외에는 절대 사용하지 않는다.

### 공통 처리: AWS SSO 토큰 만료 감지 및 반복 Slack 알림 (Step 1 이후 모든 terraform 명령에 적용)

이 스킬이 실행하는 어떤 `terraform apply`/`destroy`/`plan` 출력에서든 아래 패턴이 보이면
SSO 세션이 만료된 것이다:

- `No valid credential sources found`
- `refresh cached SSO token failed`
- `InvalidGrantException`

이 상태로 명령이 실패하면 destroy가 중단된 채 비용 발생 리소스(NAT Gateway, EKS 클러스터 등)가
그대로 남아 계속 과금된다. 감지 즉시 아래 백그라운드 루프를 시작한다 — LLM 턴을 소비하지 않는
순수 쉘 루프이므로 10초 간격 반복이 부담 없다 (`run_in_background: true`, `timeout: 600000`
— Bash 도구가 허용하는 최대 10분):

```bash
PROFILE="<해당 root/서브디렉토리 providers.tf의 profile>"
ENV_NAME="<환경>"
WEBHOOK="$SLACK_WEBHOOK_URL"
CMD_HINT="aws sso login --profile $PROFILE"
SSO_SESSION=$(awk -v p="[profile $PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f && /sso_session/{print $3}' ~/.aws/config)
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

### Step 1: kubectl context 확인

`{root}/eks/providers.tf`에서 `profile`을, `{root}/eks/locals.tf`에서 `cluster_name`을 Grep으로
확인한다. `kubectl config current-context`가 해당 클러스터가 아니면:

```bash
aws eks update-kubeconfig --name <cluster_name> --region ap-northeast-2 --profile <profile> --alias <cluster_name>
```

클러스터에 연결되지 않으면(이미 삭제됐거나 최초 생성 전) Step 2~5를 건너뛰고 Step 6으로 이동한다.

### Step 2 (비활성화 — 실행하지 않음): ArgoCD Application/ApplicationSet 삭제

**이 단계는 실행하지 않는다.** Application/ApplicationSet은 K8s 커스텀 리소스(etcd에 저장)이므로
Step 8에서 클러스터(컨트롤 플레인)를 destroy하면 etcd 자체가 사라지면서 자동으로 함께
없어진다 — 별도 조치가 불필요하다. 대신 Step 11의 zone 전체 재검증(모든 ALB·Route53
레코드를 스캔해 대응 리소스가 없는 고아를 찾아 정리)을 **반드시** 실행해 ALB/Route53
고아 여부를 사후 확인한다 (2026-07-10 monitoring teardown에서 이 단계를 생략하고
Step 11까지 실행해 Route53·ALB 모두 깨끗함을 확인했다). 바로 Step 3으로 진행한다.

과거에 이 단계가 실행하던 절차는 참고용으로만 남겨둔다 (실행하지 않음):

```bash
# kubectl get application -n argocd 2>/dev/null
# kubectl get applicationset -n argocd 2>/dev/null
# kubectl delete applicationset --all -n argocd --ignore-not-found
# kubectl delete application --all -n argocd --ignore-not-found
```

> **WHY (이 단계가 원래 존재했던 이유, 참고용)**: 2026-07-04 monitoring teardown에서 `gateway-dev` Ingress를 Step 3(당시 Step 2)
> 절차대로 삭제했지만, 그 Ingress는 ArgoCD Application `gateway-dev`(destination이
> `https://kubernetes.default.svc`인 in-cluster 배포, namespace `eks-practice-dev`)가
> 계속 소유·조정하고 있었다. `syncPolicy.automated.selfHeal=false`라 즉시 되살아나지는
> 않았지만, 실제로는 우리가 기록해둔 것과 다른 새 ALB가 이미 떠 있는 상태였고, 클러스터를
> 완전히 destroy한 뒤에도 그 ALB(및 연결된 대상 그룹·보안 그룹 2개)가 고아로 남아 수동
> 정리가 필요했다. 근본 원인은 "Ingress를 지우는 시점에 ArgoCD가 여전히 그 리소스를
> 관리 중이었다"는 것이므로, ALB DNS 이름을 사후에 재대조하는 임시방편 대신 Ingress를
> 지우기 전에 Application/ApplicationSet 자체를 먼저 제거해 ArgoCD가 어떤 시점에도 재생성·
> 교체할 수 없는 상태를 만든다. 이 환경은 dev/prod 구분 없이 여러 서비스가 namespace로만
> 분리되어 한 클러스터에 배포될 수 있으므로(같은 날 teardown에서 실제 확인됨), Application이
> 여러 개 있을 수 있다는 전제로 `--all`을 사용한다.

### Step 3: Ingress 삭제 — 잔여 ALB/Route53 정리 트리거

`kubectl get ingress -A -o json`으로 전체 Ingress를 조회한다. 없으면 이 단계 및 Step 4, 5를
건너뛰고 Step 6으로 이동한다.

각 Ingress에 대해 **삭제 전에** 아래를 기록한다 (삭제 후에는 조회 불가):
- `namespace`, `name`
- `status.loadBalancer.ingress[0].hostname` (ALB DNS 이름)
- `metadata.annotations."external-dns.alpha.kubernetes.io/hostname"` (Route53 레코드 이름)

기록 후 각각 삭제한다:

```bash
kubectl delete ingress <name> -n <namespace>
```

### Step 4: ALB 정리 완료 대기

`{root}/eks/providers.tf`의 `profile`로 아래를 polling한다 (최대 3분):

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --profile <profile> \
  --query "LoadBalancers[?DNSName=='<기록한 ALB DNS 이름>']"
```

Step 3에서 기록한 모든 ALB가 빈 결과(`[]`)가 될 때까지 대기한다.
3분 초과 시 경고를 출력하고 계속 진행한다 (Step 7에서 다시 확인 기회가 있음을 안내).
Step 2에서 Application을 이미 제거했으므로 이 시점에는 ArgoCD가 Ingress를 재생성할 수
없다 — 그래도 최종 확인은 Step 11에서 한 번 더 이뤄진다.

### Step 5: Route53 레코드 수동 삭제 — 잔여 리소스 관리 핵심

`modules/eks-addons/1.0.0`의 ExternalDNS helm_release는 `policy`를 오버라이드하지 않아
차트 기본값(`upsert-only`, 생성·갱신만 하고 삭제는 절대 하지 않음)을 그대로 쓴다.
**즉 Ingress를 지워도 ExternalDNS는 Route53 레코드를 스스로 지우지 않는다** — 이는 예외
상황이 아니라 이 프로젝트의 정상 동작이다 (2026-07-02 monitoring teardown에서
`kubectl logs`로 확인: 삭제 후에도 계속 `All records are already up to date`만 출력).

Step 3에서 기록한 `external-dns.alpha.kubernetes.io/hostname` 값이 있는 Ingress마다,
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
`external-dns/resource=ingress/<namespace>/<name>` 부분이 Step 3에서 기록한 삭제 대상
Ingress와 일치하는지도 함께 확인하면 다른 Ingress의 레코드를 잘못 지우는 실수를 방지할 수
있다 (`external-dns/owner=<id>`는 같은 zone을 여러 ExternalDNS 인스턴스가 공유할 때 어느
인스턴스 소유인지 구분하는 값이다). `heritage=external-dns` 마커가 없는 레코드는 이
자동 삭제 대상에서 제외하고 사용자에게 별도로 보고한다.

결과가 있으면(거의 항상 있음) 레코드 내용을 사용자에게 보여주고, 확인을 기다리지 않고
바로 조회된 레코드 전부(보통 A + TXT + cname- TXT 3개)를 하나의 change-batch로 DELETE한다
(teardown 자체가 이미 Step 0에서 삭제 대상으로 안내·승인된 작업이므로 레코드 단위로
다시 확인받지 않는다):

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

(각 레코드 JSON은 위 `list-resource-record-sets` 결과에서 그대로 사용한다.)

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

### Step 6: external-secrets ValidatingWebhookConfiguration 사전 제거

클러스터가 연결 가능하면 아래를 실행한다 (없으면 조용히 스킵):

```bash
kubectl delete validatingwebhookconfigurations externalsecret-validate secretstore-validate --ignore-not-found
```

> **WHY**: eks-addons destroy 그래프에서 `null_resource.karpenter_nodeclaims_drainer`가
> Karpenter 노드를 조기에 삭제하면서 external-secrets-webhook 파드도 함께 사라진다. 이후
> `kubernetes_manifest.aws_parameterstore_secret_store`(ClusterSecretStore) /
> `argocd_image_updater_git_creds` 등 ESO 의존 ExternalSecret·ClusterSecretStore 삭제가
> webhook 호출 실패(`no endpoints available for service "external-secrets-webhook"`)로
> 멈춘다. 클러스터 전체를 지우는 중이므로 검증 webhook을 미리 제거해도 안전하다 — 재시도
> 없이 한 번에 destroy가 끝난다.
>
> **참고 (GitOps Bridge 이관 후 갱신)**: ArgoCD 자신의 repo-creds
> (`kubernetes_secret_v1.argocd_github_app_repo_creds`)는 순환 의존 문제로 ESO를 거치지
> 않고 SSM Parameter Store를 직접 읽는 Terraform 네이티브 리소스로 바뀌어(`main.tf` 참고)
> 더 이상 이 webhook에 의존하지 않는다 — 이 단계가 필요한 이유는 여전히 ESO 기반으로 남은
> 나머지 ExternalSecret/ClusterSecretStore 때문이다.

### Step 7: eks-addons destroy

```bash
cd {root}/eks-addons && terraform destroy -auto-approve
```

**`Timed out when waiting for resource ... to be deleted` 에러 시** (finalizer 잔존 —
Step 6으로 대부분 예방되지만 다른 리소스에서 발생 가능):

```bash
kubectl get <kind> <name> -n <namespace> -o jsonpath='{.metadata.finalizers}'
kubectl patch <kind> <name> -n <namespace> --type=merge -p '{"metadata":{"finalizers":[]}}'
```

제거 후 destroy를 재시도한다. 그 외 에러는 사용자에게 보고 후 중단한다.

### Step 7.5: eks-addons destroy 사후 검증 — Terraform state 및 AWS API 이중 확인

Step 7이 `Destroy complete!`로 끝났다는 출력만으로 완료 처리하지 않는다. GitOps Bridge
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
Step 7이 일부만 destroy된 것이므로, 남은 리소스 주소를 사용자에게 보고하고 원인을 확인한다
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
전파가 아직 안 끝난 것이니 최대 2분 polling 후 재확인한다. 그래도 남아있으면 Step 7 destroy
결과와 모순되는 것이므로 재시도 없이 사용자에게 보고한다.

> **WHY (2026-07-18 GitOps Bridge 이관 후 도입)**: monitoring이 `modules/eks-addons/2.0.0`로
> 이관되며 Terraform이 더 이상 addon의 Helm release를 직접 만들지 않게 됐다 — Step 7의
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

이 destroy를 시작하는 즉시(완료를 기다리지 않고) **Step 10의 VPC NAT Gateway 비활성화도
병렬로 시작한다.** eks-addons가 이미 Step 7에서 삭제되어 클러스터 안에 아웃바운드가 필요한
워크로드가 남아있지 않으므로, EKS 클러스터 destroy 자체(컨트롤 플레인·노드그룹·SG 삭제는
AWS API 호출이지 고객 VPC 경유 아웃바운드가 아니다)는 NAT Gateway 유무와 무관하게 안전하게
동시 진행할 수 있다 (2026-07-04 확인 — provision 쪽 Step 1/2 병렬화와 같은 근거).

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
   (A + 해당 TXT + `cname-` TXT 3개를 하나의 change-batch로) 삭제한다.
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
```

두 명령 결과가 모두 비어있으면 완료 메시지를 출력한다:

```
[완료] <환경> 비용 발생 리소스 삭제 완료
- ArgoCD Application/ApplicationSet: 삭제 완료
- eks-addons: 삭제 완료 (Terraform state 비어있음 + IAM/SQS/EventBridge AWS API 확인 완료)
- EKS 클러스터: 삭제 완료
- kubeconfig: context/cluster/user 정리 완료
- NAT Gateway: 비활성화
- VPC/서브넷/파라미터 스토어: 유지 (비용 없음)

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
