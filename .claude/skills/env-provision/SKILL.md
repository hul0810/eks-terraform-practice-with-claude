---
name: env-provision
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(VPC NAT Gateway, EKS 클러스터, eks-addons)를
  올바른 순서로 생성한다. Karpenter/external-secrets CRD 순환 의존은 eks-addons 코드 주석이 명시한
  2단계 apply(-target=module.eks_addons 선행)로 선제 회피하고, LBC-ArgoCD 웹훅 경쟁 상태,
  ExternalDNS cross-account role 신뢰 정책 갱신(필요한 환경만) 등 나머지 반복 실패 패턴은
  발생 시 감지해 재시도한다. 3개 환경 모두 실습용이므로 production도 대상이다.
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

**3-1. 선행 CRD 설치 — 항상 먼저 실행 (전체 apply를 바로 시도하지 않는다)**

`{root}/eks-addons/main.tf` 상단 주석(`⚠️ 첫 배포 또는 Karpenter 재설치 시 2단계 apply 필수`)이
이미 명시하듯, Step 2에서 클러스터를 새로 만든 직후에는 Karpenter/external-secrets CRD가
클러스터에 없어 `kubernetes_manifest` 리소스의 plan 자체가 **항상** 실패한다
(`hashicorp/kubernetes` provider가 plan 단계에서 클러스터 API로 CRD 스키마를 직접 조회하기
때문에 `depends_on`으로는 막을 수 없다). 이 실패가 예정돼 있다는 것을 코드가 이미 알려주므로,
전체 apply를 먼저 시도해 실패를 확인하는 절차를 생략하고 module 전체를 target으로 먼저
적용한다:

```bash
cd {root}/eks-addons && terraform apply -auto-approve -target=module.eks_addons
```

> **WHY (2026-07-07 확인)**: 이전에는 3-2(전체 apply)를 먼저 시도해 매번 CRD 에러로
> 실패를 확인한 뒤에야 `-target`으로 좁혀 재시도했다. `main.tf`의 코드 주석이 이미
> "1단계: `terraform apply -target=module.eks_addons`"를 명시하고 있으므로, 실패가
> 확정적인 시도를 거치지 않고 이 순서를 그대로 선행 실행한다. target 범위도 기존의
> karpenter/external_secrets helm_release 2개만이 아니라 `module.eks_addons` 전체로
> 넓혀, LBC/ArgoCD/external-dns/argo-rollouts 등 CRD와 무관한 나머지 애드온도 이
> 1단계에서 함께 설치되게 한다 — 단, ArgoCD의 Ingress는 이 module 안에 포함되므로
> 3-3의 LBC 웹훅 경쟁은 이 1단계에서도 여전히 발생할 수 있다(아래 참고).

**3-2. 전체 apply**

```bash
cd {root}/eks-addons && terraform apply -auto-approve
```

**3-3. LBC 웹훅 경쟁 상태 감지 시 (3-1, 3-2 어느 단계에서 발생해도 동일하게 처리)**

아래 패턴이 있으면 LBC와 ArgoCD(Ingress 포함)가 병렬 생성되며 LBC 웹훅이 아직 뜨기 전에
ArgoCD Ingress 생성이 시도된 것이다 (일시적 — `module.eks_addons` 안에서 병렬 생성되므로
3-1 단계에서도 나타날 수 있다):

- `no endpoints available for service "aws-load-balancer-webhook-service"`

`kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`로
LBC 파드가 `Running`인지 확인 후 **직전에 실패한 단계(3-1 또는 3-2)를 그대로 재실행**한다
(최대 2회).

**3-4. external-secrets 웹훅 미기동 감지 시**

아래 패턴이 있으면 external-secrets-webhook 파드가 아직 뜨지 않은 것이다.
초기 부트스트랩 시 Karpenter가 새 노드를 프로비저닝하는 데 1~2분 걸릴 수 있어
파드가 `Pending` 상태로 남아있을 수 있다:

- `no endpoints available for service "external-secrets-webhook"`

`kubectl get pods -n external-secrets`로 3개 파드(`external-secrets`,
`external-secrets-cert-controller`, `external-secrets-webhook`)가 모두 `Running`인지 확인
(최대 3분 polling) 후 **3-2의 전체 apply를 재실행**한다.

**3-5. 그럼에도 CRD 순환 의존 에러가 나타나는 경우** (3-1이 어떤 이유로 생략됐거나 module
구조 변경으로 target 범위가 CRD 설치를 커버하지 못하게 된 경우의 대비책):

- `no matches for kind "EC2NodeClass" in group "karpenter.k8s.aws"`
- `no matches for kind "ClusterSecretStore" in group "external-secrets.io"`

3-1을 그대로 재실행해 CRD 설치를 확인한 뒤 (`kubectl get crd | grep -E "karpenter|external-secrets"`),
3-2를 재실행한다.

**3-6.** 위 패턴에 해당하지 않는 다른 에러는 재시도하지 말고 사용자에게 보고 후 중단한다.

### Step 4: cross-account ExternalDNS 신뢰 정책 갱신 (조건부)

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
2. `kubectl get ingress -A`로 각 Ingress에 ALB 주소(ADDRESS)가 할당됐는지 확인
3. Ingress가 있으면 `external-dns.alpha.kubernetes.io/hostname` 값을 각각 확인하고,
   `{root}/eks-addons/locals.tf`에서 `external_dns_route53_zone_arns`를 Grep해 zone ID를 추출한 뒤:

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
     --query "ResourceRecordSets[?Name=='<hostname>.']"
   ```

   A 레코드의 `AliasTarget.DNSName`이 현재 Ingress의 ALB 주소와 일치하는지 확인
   (최대 2분 polling — ExternalDNS 반영 지연 감안).

4. 완료 안내를 출력한다.

```
[완료] <환경> 리소스 생성 완료
- VPC NAT Gateway: 활성화
- EKS 클러스터: <cluster_name>
- eks-addons: 생성 완료
- Ingress: <hostname 목록과 상태>
```
