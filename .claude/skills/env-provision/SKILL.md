---
name: env-provision
description: >
  develop/monitoring/production 실습 환경의 비용 발생 리소스(VPC NAT Gateway, EKS 클러스터, eks-addons)를
  올바른 순서로 생성한다. 모든 환경이 GitOps Bridge(modules/eks-addons/2.0.0)를 쓰는 지금은
  Karpenter/ESO의 kubernetes_manifest가 ArgoCD 소관이라 CRD 순환 의존 자체가 없다 — ArgoCD
  부트스트랩만 -target=module.eks_addons로 선행 apply하면 addon 17개 등록·sync는 전부 자동화돼
  있어(devops-manifest의 automated syncPolicy) 사람이 순서를 정할 필요가 없다. LBC 웹훅 준비
  전 다른 addon이 먼저 reconcile을 시도하는 일시적 경쟁 상태, ExternalDNS cross-account role
  신뢰 정책 갱신(필요한 환경만) 등 반복 실패 패턴은 발생 시 감지해 재시도한다. 3개 환경 모두
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
> teardown된 상태면 이 Role이 없어 publish가 provider 단계에서부터 막힌다. 여러 환경을 한
> 요청으로 provision하면(예: "monitoring이랑 develop 둘 다 켜줘") **항상 monitoring을 먼저
> 끝내고 develop/production을 그 다음에 처리한다.** `develop`/`production` 단독 호출이어도
> Step 3 진입 전 아래로 선행조건을 확인한다:
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

**3-B-1. ArgoCD 부트스트랩 + addon IAM만 선행 apply**

`-target=module.eks_addons`는 이 root의 `module.eks_addons` **안**의 리소스만 적용하고,
바깥에 있는 `kubernetes_manifest`(ESO ClusterSecretStore/ExternalSecret, Karpenter
NodeClass/NodePool 등)는 원래도 건드리지 않으므로 3-A-1과 동일한 명령을 그대로 쓴다:

```bash
cd {root}/eks-addons && terraform apply -auto-approve -target=module.eks_addons
```

이 시점에 ArgoCD 자체(Helm)와 LBC/Karpenter/ExternalDNS/ExternalSecrets의 IAM Role/Policy,
Karpenter의 SQS 인터럽션 큐·EventBridge Rule, `argocd-github-app-repo-creds` Secret(SSM에서
직접 읽어 Terraform이 만듦 — ESO 비의존)까지 전부 준비된다. ArgoCD는 이 시점부터 자기
저장소(devops-manifest)를 정상적으로 sync할 수 있다.

**3-B-1.5. registry publish + Hub 재apply — spoke(develop/production) 환경은 필수
(2026-07-23 도입 — 이전까지 절차에 빠져있던 단계, 실제로 매번 수동 처리했었다)**

이 root(`{root}/eks-addons`)에 `gitops-bridge-registry.tf`가 있는 환경(현재 develop/
production — monitoring은 Hub 자신이라 해당 없음)은 3-B-1만으로 끝나지 않는다.
`module.eks_addons` 바깥의 `aws_ssm_parameter.gitops_bridge_registry`가 아직 apply되지
않아 SSM에 이 클러스터의 registry payload가 없고, Hub(monitoring)도 아직 이 클러스터를
spoke로 discovery하지 못한 상태다 — addon Application 자체가 생성되지 않는다.

```bash
cd {root}/eks-addons && terraform apply -auto-approve
```

이 전체 apply로 SSM에 registry payload가 publish된다(`gitops-bridge-registry.tf`). 이어서
**반드시 Hub(monitoring) 쪽 eks-addons를 한 번 더 apply**해야 한다 — publish 시점과
Hub가 discovery하는 시점이 다르기 때문이다(Hub의 `data.aws_ssm_parameter`/`for_each`가
plan 시점에 SSM을 다시 읽어야 새 spoke를 인식한다):

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

**3-B-3. sync 중 LBC 웹훅 경쟁 감지 시**

- `no endpoints available for service "aws-load-balancer-webhook-service"`

LBC 파드가 `Running`인지 재확인 후 실패한 addon의 sync만 재실행한다(최대 2회).

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
2. **3-B(GitOps Bridge) 절차를 탔다면 추가로** `argocd app list --core`로 3-B-2에서 등록한
   addon Application들의 `SYNC STATUS`/`HEALTH STATUS`가 모두 `Synced`/`Healthy`인지 확인한다.
   `OutOfSync`나 `Degraded`가 있으면 `argocd app get <name> --core`로 원인을 확인 후 보고한다
   (3-A 절차만 탄 환경은 이 항목을 건너뛴다 — addon이 전부 Terraform Helm이라 별도 확인 불필요).
3. `kubectl get ingress -A`로 각 Ingress에 ALB 주소(ADDRESS)가 할당됐는지 확인
4. Ingress가 있으면 `external-dns.alpha.kubernetes.io/hostname` 값을 각각 확인하고,
   `{root}/eks-addons/locals.tf`에서 `external_dns_route53_zone_arns`를 Grep해 zone ID를 추출한 뒤:

   ```bash
   aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --profile terraform-workload \
     --query "ResourceRecordSets[?Name=='<hostname>.']"
   ```

   A 레코드의 `AliasTarget.DNSName`이 현재 Ingress의 ALB 주소와 일치하는지 확인
   (최대 2분 polling — ExternalDNS 반영 지연 감안).

5. 완료 안내를 출력한다.

```
[완료] <환경> 리소스 생성 완료
- VPC NAT Gateway: 활성화
- EKS 클러스터: <cluster_name>
- eks-addons: 생성 완료
- Ingress: <hostname 목록과 상태>
```
