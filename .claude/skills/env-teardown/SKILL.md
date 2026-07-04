---
name: env-teardown
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(eks-addons, EKS 클러스터, VPC NAT Gateway)를
  역순으로 삭제한다. terraform destroy만으로는 정리되지 않는 잔여 리소스
  (ArgoCD Application/ApplicationSet가 재조정 중인 Ingress·ALB, workload 계정 Route53에
  ExternalDNS가 만든 레코드, karpenter 노드 조기 drain으로 발생하는 external-secrets 웹훅 교착,
  삭제된 클러스터를 가리키는 ~/.kube/config 잔여 context/cluster/user 항목)까지 함께 관리한다.
  VPC 자체·서브넷·파라미터 스토어 등 비용이 없는 리소스는 삭제하지 않는다. 3개 환경 모두
  실습용이므로 production도 대상이다.
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

### Step 1: kubectl context 확인

`{root}/eks/providers.tf`에서 `profile`을, `{root}/eks/locals.tf`에서 `cluster_name`을 Grep으로
확인한다. `kubectl config current-context`가 해당 클러스터가 아니면:

```bash
aws eks update-kubeconfig --name <cluster_name> --region ap-northeast-2 --profile <profile> --alias <cluster_name>
```

클러스터에 연결되지 않으면(이미 삭제됐거나 최초 생성 전) Step 2~5를 건너뛰고 Step 6으로 이동한다.

### Step 2: ArgoCD Application/ApplicationSet 삭제 — 재조정 경쟁 방지

`argocd` 네임스페이스가 있으면(ArgoCD 설치 여부) Application/ApplicationSet 리소스를 조회한다:

```bash
kubectl get application -n argocd 2>/dev/null
kubectl get applicationset -n argocd 2>/dev/null
```

둘 다 없으면 이 단계를 건너뛴다. 있으면 **ApplicationSet부터** 삭제해 자식 Application이
다시 생성되지 못하게 막은 뒤, Application을 전부 삭제한다 (app-of-apps 패턴이어도 부모
Application 하나만 지우면 자식은 그대로 남으므로 반드시 전체를 대상으로 한다):

```bash
kubectl delete applicationset --all -n argocd --ignore-not-found
kubectl delete application --all -n argocd --ignore-not-found
```

`--all` 삭제는 기본적으로 non-cascade이므로 Application이 관리하던 실제 K8s 리소스
(Deployment/Service/Ingress 등)는 지워지지 않는다 — ArgoCD의 관리 소유권만 해제되고,
남은 리소스는 Step 3(Ingress) 이후 단계와 클러스터 destroy(Step 7~8)가 정리한다.

> **WHY**: 2026-07-04 monitoring teardown에서 `gateway-dev` Ingress를 Step 3(당시 Step 2)
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
> `kubernetes_manifest.argocd_github_app_repo_creds` / `argocd_github_app_secret_store` 등
> ExternalSecret·ClusterSecretStore 삭제가 webhook 호출 실패(`no endpoints available for
> service "external-secrets-webhook"`)로 멈춘다. 클러스터 전체를 지우는 중이므로 검증
> webhook을 미리 제거해도 안전하다 — 재시도 없이 한 번에 destroy가 끝난다.

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

### Step 8: EKS 클러스터 destroy

```bash
cd {root}/eks && terraform destroy -auto-approve
```

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

### Step 10: VPC NAT Gateway 비활성화

`{root}/vpc/locals.tf`를 Read하여 `enable_nat_gateway`가 이미 `false`면 스킵.
`true`면 Edit로 `false`로 변경 후:

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

### Step 11: 완료 안내 및 잔여 비용 리소스 최종 확인

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 --profile <profile>
aws ec2 describe-nat-gateways --region ap-northeast-2 --profile <profile> \
  --filter "Name=state,Values=available,pending"
```

두 명령 결과가 모두 비어있으면 완료 메시지를 출력한다:

```
[완료] <환경> 비용 발생 리소스 삭제 완료
- ArgoCD Application/ApplicationSet: 삭제 완료
- eks-addons: 삭제 완료
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
