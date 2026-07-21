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

> **production eks-addons 선행조건 가드(2026-07-22 갱신 — SSM 레지스트리 self-service 방식으로 전환)**:
> production의 `eks-addons` root는 이미 코드상 `modules/eks-addons/2.0.0`(GitOps Bridge)을
> 가리킨다 — 즉 Terraform은 addon Helm을 아예 설치하지 않고 IAM만 만든다. 이 상태로 Step 3을
> 그대로 진행하면 **addon Helm이 전혀 설치되지 않는 클러스터**(LBC/Karpenter/ExternalDNS/
> ExternalSecrets 파드가 없는 상태)가 될 수 있다 — ArgoCD가 이 addon들을 가져가려면 먼저
> production이 monitoring(Hub)에 spoke로 등록되어 있어야 한다.
>
> **구 방식(더 이상 없음)**: monitoring의 `gitops-bridge-spokes.tf`에 있던
> `gitops_bridge_spokes.prod.enabled` 플래그를 손으로 뒤집는 방식은 2026-07-22 self-service
> 레지스트리 도입으로 사라졌다 — 이 필드 자체가 코드에 없다.
>
> **현재 방식**: production 자신이 `project/environments/production/.../eks-addons/`에
> `develop/.../eks-addons/gitops-bridge-registry.tf`·해당 `locals.tf`의
> `gitops_bridge_registry_payload`·`providers.tf`의 `aws.gitops_bridge_registry` provider를
> 그대로 본떠 자기 파일을 만들고(2026-07-22 시점 production에는 아직 이 파일이 없음 — 최초
> 1회 신규 작성 필요), `addon_managed = true`로 apply해서 SSM에 자기 등록 정보를 publish해야
> 한다. 그 후 monitoring(Hub) 쪽 `eks-addons`를 **한 번 더 apply**해야 discovery가
> production을 인식하고 cluster Secret을 만든다(발행 시점과 Hub가 아는 시점이 다르다 —
> `temp/gitops-bridge-registry-summary.md` 참고). Step 3 진행 전 production의 registry 파일이
> 있는지, monitoring이 이미 discovery했는지(`kubectl get secret prod -n argocd` 등)를 확인하고,
> 없다면 사용자에게 먼저 이 등록 작업이 필요하다고 안내한 뒤 진행 여부를 다시 확인한다.
>
> **참고(미해결 갭)**: `addon_managed = true`로 등록해도, devops-manifest의 `-spoke`
> ApplicationSet들이 실제로는 이 값(라벨)을 selector에서 확인하지 않는 것으로 확인됐다
> (`temp/gitops-bridge-addon-managed-label-unused-gap.md`) — 즉 지금은 `gitops-bridge-role:
> spoke`만 있으면 addon_managed 값과 무관하게 addon이 배포될 수 있다. production을 처음
> 등록하기 전 이 갭이 해소됐는지 먼저 확인할 것 — 안 그러면 production이 아직 자기
> Terraform으로 addon을 관리 중인 상태에서 ArgoCD가 동시에 배포를 시도해 충돌할 수 있다.

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
> 3-A-3의 LBC 웹훅 경쟁은 이 1단계에서도 여전히 발생할 수 있다(아래 참고).

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

**3-B-2. ArgoCD로 addon 등록 — 순서 중요**

> **갱신(2026-07-19, devops-manifest 커밋 0d0929c 이후)**: `argocd/eks-addons/*.yaml` 10개를
> devops-manifest가 `argocd/applicationsets/eks-addons/`로 옮기고 root Application에
> `directory.recurse: true`를 추가해, 이 10개 Application **객체 자체의 생성/유지는 이제
> root Application이 자동으로 한다** — 파일을 가져와 `kubectl apply -f`로 등록하는 절차는
> 더 이상 필요 없다.
>
> **정정(2026-07-21)**: 진입점은 `root-app.yaml` 1개가 아니라 **2개로 분리**돼 있다 —
> addon용 `argocd/root-app-addons.yaml`(path: `argocd/applicationsets/eks-addons`)과
> workload용 `argocd/root-app-workload.yaml`(path: `argocd/applicationsets/workload`).
> eks-addons만 다루는 이 스킬은 `root-app-addons.yaml`만 있으면 된다 — devops-manifest의
> `argocd/CLAUDE.md`가 "App of Apps 진입점, 유일하게 수동 kubectl apply가 필요한 리소스"라고
> 명시한 파일이 바로 이거다.
>
> 다만 이 10개 Application은 `syncPolicy`가 여전히 `Manual`이다(라이브에서
> `argocd app list --core`의 SYNCPOLICY 컬럼으로 직접 확인 — automated로 바뀐 게 아니다).
> 즉 root-app-addons가 Application **객체**는 자동으로 만들어주지만, 그 안의 실제 Helm
> release를 클러스터에 반영하는 것(`argocd app sync`)은 여전히 아래 절차대로 수동이다 —
> "파일 등록"만 사라졌을 뿐 "sync 순서" 자체는 그대로 유효하다.
>
> **부수 발견(2026-07-21) — `eks-addons` AppProject도 클러스터 재구축 시 함께 사라진다**:
> `root-app-addons.yaml`이 감시하는 경로(`argocd/applicationsets/eks-addons/`)에
> `eks-addons` AppProject(`argocd/projects/eks-addons.yaml`)가 포함되어 있지 않아서,
> EKS 클러스터를 destroy하면 이 AppProject도 etcd와 함께 사라지고 재구축 시 자동으로
> 안 돌아온다 — 없으면 10개 Application 전부 아래 에러로 막힌다:
> `application destination server 'in-cluster' and namespace '' do not match any of
> the allowed destinations in project 'eks-addons'`
> devops-manifest 쪽에 이 AppProject를 root-app-addons의 감시 경로 안으로 옮겨달라고
> 요청했다(2026-07-21) — 반영 전이면 아래처럼 두 파일 다 최초 1회 수동 적용해야 한다.

`root-app-addons`가 없다면 아래 순서로 최초 1회 부트스트랩한다:

```bash
gh api repos/hul0810/eks-practice-devops-manifest/contents/argocd/root-app-addons.yaml --jq '.content' | base64 -d | kubectl apply -f -
gh api repos/hul0810/eks-practice-devops-manifest/contents/argocd/projects/eks-addons.yaml --jq '.content' | base64 -d | kubectl apply -f -
```

그 후 `argocd app sync <name> --core`로 sync한다(`--core`는 kubeconfig 권한으로 로그인 없이
동작 — `docs/`나 이전 세션 기록 참고).

순서:
1. **LBC를 가장 먼저** sync하고 `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`로 `Running` 확인 (다른 addon의 Service 생성이 LBC의 mutating webhook을 거치는데, LBC가 안 뜬 상태면 아래 3-B-3과 같은 웹훅 경쟁이 재발한다)
2. 나머지(Karpenter, ExternalDNS, ExternalSecrets, metrics-server, argo-rollouts, argocd-image-updater)를 순서 무관하게 sync
3. 마지막으로 `karpenter-resources`/`argocd-image-updater-resources`/`notifications-resources`(CRD 의존 3종) sync — 2번의 addon들이 뜬 뒤에만 가능

**3-B-2-보조. cluster-scoped 리소스 Application이 `InvalidSpecError`로 막힐 때**

`karpenter-resources`/`argocd-image-updater-resources`/`notifications-resources` 3개는
namespace 없는 cluster-scoped 리소스라 `destination.namespace`가 빈 문자열이다. `eks-addons`
AppProject의 `destinations` 목록에 이걸 허용하는 항목이 없으면 위와 같은
`InvalidSpecError`("namespace '' do not match")로 막힌다(2026-07-21 실제 발생, devops-manifest에
근본 수정 요청함 — AppProject 자체에 `{namespace: "*", server: "https://kubernetes.default.svc"}`
destination 추가). 반영 전이면 임시로 라이브 패치한다:

```bash
kubectl patch appproject eks-addons -n argocd --type=json \
  -p='[{"op": "add", "path": "/spec/destinations/-", "value": {"namespace": "*", "server": "https://kubernetes.default.svc"}}]'
```

**3-B-2-보조 2. addon 전용 namespace가 없어서 apply/sync가 막힐 때**

`argo-rollouts`/`external-dns`/`external-secrets`/`karpenter` 같은 addon 전용 namespace는
과거 Terraform Helm이 만들어주던 게 이관 후 사라졌다 — devops-manifest ApplicationSet에
`CreateNamespace=true`가 없으면 클러스터를 처음부터 재구축했을 때 그 namespace가 존재하지
않는다(karpenter는 2026-07-20 devops-manifest 쪽에서 이미 수정됨, 나머지는 미확인). 이
namespace가 없으면 `terraform apply`의 `kubernetes_service_account_v1`류 리소스나
`argocd app sync`가 `namespaces "X" not found`로 막힌다 — `kubectl create namespace <name>`으로
수동 생성 후 재시도한다(devops-manifest 쪽 수정 요청서는 이미 전달됨, 반영되면 이 단계 불필요).

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
