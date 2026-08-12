# EKS 애드온 설치 전략

## 실무 최소 애드온 목록

AWS 공식 문서에 "최소 애드온" 명시 기준은 없다. 아래는 이 프로젝트 기능 요구사항 기반 목록이다.

| 애드온 | 분류 | 없으면 |
|--------|------|--------|
| `vpc-cni` | Bootstrap | 노드가 클러스터 조인 자체 실패 |
| `kube-proxy` | Bootstrap | ClusterIP/NodePort 트래픽 라우팅 전면 실패 |
| `coredns` | Bootstrap | 서비스명 DNS 해석 불가, 클러스터 내 통신 장애 |
| `eks-pod-identity-agent` | Bootstrap | Karpenter 등 Pod Identity 의존 컴포넌트 IAM 연동 실패 |
| `aws-ebs-csi-driver` | Bootstrap | PVC(EBS) 생성 불가, StatefulSet 기동 실패 |
| `cert-manager` | Bootstrap | TLS 인증서 자동화 불가, OpenTelemetry Operator 등 설치 불가 |
| `aws-load-balancer-controller` | Helm (blueprints) | Ingress/ALB Service 프로비저닝 안 됨 |
| `external-dns` | Helm (blueprints) | Route53 레코드 수동 관리 필요 |
| `metrics-server` | Helm (blueprints) | `kubectl top` 불가, HPA 동작 안 함 |
| `karpenter` | Helm (blueprints) | 노드 자동 프로비저닝 없어 Pending Pod 무한 대기 |
| `argocd` | Helm (gitops-bridge) — **monitoring(Hub) 클러스터에만** | GitOps 동기화 불가. dev/prd는 Hub의 spoke로 등록되어 자체 설치하지 않는다 |
| `argo-rollouts` | Helm (blueprints) | Canary·Blue-Green 배포 불가, Rollout 리소스 처리 안 됨 |
| `external-secrets` | Helm (blueprints) | AWS SSM Parameter Store/Secrets Manager 값을 K8s Secret으로 동기화 불가, 시크릿 수동 관리 필요 |
| `cluster-autoscaler` | Helm (blueprints) | 시스템 MNG(정적 노드 그룹)가 pod 슬롯 부족으로 포화돼도 확장되지 않음 |
| `keda` | Helm (GitOps) | 큐 깊이·외부 메트릭 기반 스케일 불가 (HPA는 CPU/메모리 등 리소스 메트릭만) |
| `kube-state-metrics` | Helm (GitOps) | K8s 오브젝트 상태 메트릭 부재 — Metrics Server(리소스 메트릭)와 대상이 다름 |
| `opentelemetry-operator` | Helm (GitOps) | 텔레메트리 수집 파이프라인(OTel Collector CR) 배포 불가 |

> **Karpenter와 Cluster Autoscaler를 함께 쓴다.** 두 오토스케일러는 관리 대상 노드 집합이
> 다르며(CA=시스템 MNG의 ASG, Karpenter=NodeClaim), 겹치면 같은 Pending Pod에 둘 다 반응해
> 노드가 중복 프로비저닝된다. 그래서 **taint/toleration + nodeAffinity로 대상을 명시적으로
> 분리하는 것을 전제 조건으로 도입한다** — 아래 "오토스케일러 이원화와 노드 배치 규칙" 참조.

---

## 설치 방식 결정 기준

애드온마다 `aws_eks_addon`(Bootstrap)과 `Helm(Blueprints)` 중 하나를 선택한다.

| 기준 | aws_eks_addon (Bootstrap) | Helm (Blueprints) |
|------|--------------------------|-------------------|
| 관리 주체 | AWS가 직접 만들고 클러스터 lifecycle과 결합 | 외부 프로젝트 (CNCF, 오픈소스) |
| 커스터마이징 | `configuration_values`(JSON)로 제한적 | Helm values 자유롭게 설정 |
| 버전 관리 | AWS Console/CLI에서 자동 검증·추천 | Chart 버전 직접 관리 |

### 최소 설치 애드온 분류

| 애드온 | 방식 | 이유 |
|--------|------|------|
| VPC CNI | Bootstrap (`aws_eks_addon`) | AWS 관리형, 노드 조인 전제 조건 |
| kube-proxy | Bootstrap (`aws_eks_addon`) | AWS 관리형, ClusterIP/NodePort 라우팅 핵심 |
| CoreDNS | Bootstrap (`aws_eks_addon`) | AWS 관리형, 클러스터 DNS 핵심. Deployment 기반이므로 `before_compute = false`로 노드 후 설치 |
| EKS Pod Identity Agent | Bootstrap (`aws_eks_addon`) | AWS 관리형, Karpenter 등 Pod Identity 의존 컴포넌트 전제 조건 |
| EBS CSI Driver | Bootstrap (`aws_eks_addon`) | AWS 관리형, 클러스터 초기화 시 필요 |
| cert-manager | Bootstrap (`aws_eks_addon`) | EKS 커뮤니티 애드온(2025-03 출시). OpenTelemetry Operator 등 인증서 자동화 전제 조건 |
| AWS LB Controller | Helm (Blueprints) | EKS 관리형 없음, Helm values 커스터마이징 필요 |
| ExternalDNS | Helm (Blueprints) | Route53 zone 등 Helm values 커스터마이징 필요 |
| Metrics Server | Helm (Blueprints) | Helm values 커스터마이징 필요 |
| Karpenter | Helm (Blueprints) | EKS 관리형 없음, EC2NodeClass·NodePool 등 values 커스터마이징 필수 |
| ArgoCD | Helm (`gitops-bridge-dev/gitops-bridge/helm`) | monitoring(Hub) 전용 — Hub 하나가 dev/prd spoke를 원격 관리하므로 클러스터마다 설치하지 않는다. AWS API 미호출로 IAM 불필요 |
| Argo Rollouts | Helm (Blueprints) | Canary·Blue-Green 배포 전략 구현. AWS API 미호출로 IAM 불필요 |
| External Secrets Operator | Helm (Blueprints) | EKS 관리형·커뮤니티 add-on 카탈로그 어디에도 없음, IRSA 자동 처리 필요. Secrets Store CSI Driver + ASCP를 대체 — 아래 "Secrets Store CSI Driver 대신 External Secrets Operator를 쓰는 이유" 참조 |

---

## 애드온 분류

### Bootstrap 애드온 — `modules/eks`에서 관리

클러스터 초기화 시 함께 배포되는 애드온. 클러스터 lifecycle과 묶여 있으므로
`modules/eks/1.0.0/main.tf`에서 관리한다.

Bootstrap 애드온 6종은 모두 `module "eks"` 내 `addons` 블록에 선언하며, `before_compute` 파라미터로 배포 순서를 제어한다. 별도 서브모듈 호출이나 외부 `aws_eks_addon` 리소스가 불필요하다:

**before_compute = true — 노드 그룹 이전 배포**

클러스터 생성 직후 노드 그룹보다 먼저 배포된다. 노드 조인 전 ACTIVE 상태가 보장되어야 하는 애드온.

| 애드온 | EKS 이름 | IAM | 비고 |
|--------|----------|-----|------|
| EKS Pod Identity Agent | `eks-pod-identity-agent` | 없음 | DaemonSet. aws-node Pod Identity 크레덴셜 획득 전제 조건 |
| Amazon VPC CNI | `vpc-cni` | Pod Identity | DaemonSet. ACTIVE 보장 후 노드 조인 → CNI 초기화 실패 방지 |

> **순서 보장**: Pod Identity는 OIDC Provider ARN이 불필요하므로 `aws_iam_role.vpc_cni`, `aws_iam_role.ebs_csi`를
> `module.eks` 호출 전에 선언해도 순환 의존성이 발생하지 않는다.
> IAM Role ARN은 `addons.*.pod_identity_association`으로 전달한다.

**before_compute = false (기본값) — 노드 그룹 이후 배포**

모듈이 내부적으로 `depends_on = [module.eks_managed_node_group]`을 자동 추가한다.

| 애드온 | EKS 이름 | IAM | 비고 |
|--------|----------|-----|------|
| kube-proxy | `kube-proxy` | 없음 | DaemonSet. EKS가 노드 없이도 즉시 ACTIVE 표시 |
| CoreDNS | `coredns` | 없음 | Kubernetes Deployment. 노드 없이는 Pod 스케줄 불가 — before_compute = false로 노드 완료 후 설치 보장 |
| Amazon EBS CSI Driver | `aws-ebs-csi-driver` | Pod Identity | EKS가 노드 없이도 즉시 ACTIVE 표시 |
| cert-manager | `cert-manager` | 없음 | Deployment. 노드 없이는 ACTIVE 불가. IAM 불필요 — AWS API 미호출. EKS 커뮤니티 애드온(2025-03 출시) |

> **coredns 처리 방식**: coredns를 `before_compute = true`로 설정하면 노드 그룹보다 먼저 배포되어
> Pod 스케줄 불가 → ACTIVE 대기 → 노드 그룹 생성 불가 데드락이 발생한다.
> `before_compute = false`(기본값)로 선언하면 모듈이 노드 그룹 완료 후 자동으로 설치하여 데드락 없이 동일한 안전성을 보장한다.

### Helm 전용 애드온 — `modules/eks-addons`에서 관리

`aws-ia/eks-blueprints-addons` 모듈(`modules/eks-addons/2.0.0`)로 관리하되, **GitOps
Bridge 이관 완료 이후로는 이 모듈이 IAM(필요한 addon만)만 유지하고 실제 Helm release
설치는 ArgoCD(devops-manifest)가 담당한다** — blueprints가 IAM+Helm을 함께 자동 처리하던
것은 과거(`modules/eks-addons/1.0.0`, DEPRECATED — GitOps Bridge 패턴이 아닌 구조,
현재 참조하는 환경 없음) 이야기다. 정확한 인스턴스
구성·state 이전 절차는 `modules/eks-addons/2.0.0/CLAUDE.md`가 최신 기준이다.

| 애드온 | Helm 설치 주체 | IAM | 비고 |
|--------|---------------|-----|------|
| AWS Load Balancer Controller | ArgoCD(GitOps Bridge) | IRSA(Terraform 유지) | |
| ExternalDNS | ArgoCD(GitOps Bridge) | IRSA(Terraform 유지) | `enable_external_dns = false`로 IAM 자체 비활성화 가능 |
| Metrics Server | ArgoCD(GitOps Bridge) | 없음 | Terraform은 이 addon에 전혀 관여하지 않음 |
| Karpenter | ArgoCD(GitOps Bridge, EC2NodeClass/NodePool 포함) | IRSA(컨트롤러+노드 IAM Role+SQS+EventBridge, Terraform 유지) | `enable_karpenter = false`로 IAM 자체 비활성화 가능 |
| Cluster Autoscaler | ArgoCD(GitOps Bridge) | IRSA(Terraform 유지) | `modules/eks`의 시스템 노드 그룹(정적 Managed Node Group) 전용 — Karpenter의 general NodePool과는 별개 대상. `enable_cluster_autoscaler = false`로 IAM 자체 비활성화 가능 |
| ArgoCD | **Terraform**(`gitops-bridge-dev/gitops-bridge/helm`) — 영구 부트스트랩 예외 | 없음(Hub 자신의 크로스 계정 spoke 관리용 Pod Identity는 root `gitops-bridge-irsa.tf`에 별도 손코드로 존재) | 자기 자신을 GitOps로 관리할 수 없어 유일하게 계속 Terraform이 Helm까지 관리 |
| Argo Rollouts | ArgoCD(GitOps Bridge) | 없음 | Terraform은 이 addon에 전혀 관여하지 않음(devops-manifest의 ArgoCD Application이 처음부터 전담) |
| External Secrets Operator | ArgoCD(GitOps Bridge) | IRSA(Terraform 유지, 스코프는 호출자가 명시) | `enable_external_secrets = false`로 IAM 자체 비활성화 가능. ArgoCD repo-creds는 ESO를 거치지 않고 Terraform이 SSM을 직접 읽어 만든다(아래 "GitOps 관리 경계" 참조) |

> **환경별 이관 상태**: monitoring·develop은 위 표대로 완전히 전환 완료. production은 코드는
> 동일하게 전환됐으나 `terraform apply`가 CLAUDE.md "Production 배포 정책"에 따라 보류
> 상태다(사용자가 직접 실행).

### Hub/Spoke 배포 대상 구분

GitOps Bridge로 이관된 애드온이라도 hub(monitoring)와 spoke(dev/prod)에 동일하게 배포되는 것은
아니다. hub 자신도 ArgoCD가 설치된 실제 워크로드 클러스터이므로 자기 몫의 LBC·Karpenter 등이
별도로 필요하지만, ArgoCD의 control-plane 구성요소는 클러스터마다 복제할 대상이 아니다.

| 구분 | 애드온 | destination |
|------|--------|-------------|
| Dual — hub·spoke 각각 독립 배포 | AWS Load Balancer Controller, Karpenter, Karpenter Resources(NodePool/EC2NodeClass), ExternalDNS, External Secrets Operator, Metrics Server, Argo Rollouts | hub: `in-cluster` 고정 / spoke: `{{name}}` 템플릿(등록된 클러스터로 라우팅) |
| Hub 전용 — spoke 대응 파일 없음 | ArgoCD Image Updater(+Resources), Notifications Resources | `in-cluster` 고정. ArgoCD 자신의 control-plane 구성요소(Git/ArgoCD API 중앙 감시, Notifications 컨트롤러용 Secret)라 monitoring 하나로 충분 |
| Hub에서만 Terraform이 직접 Helm 설치 (GitOps 대상 아님) | ArgoCD | 부트스트랩 순환 의존성 예외 — 위 "GitOps 관리 경계" 절 참조 |

ApplicationSet 정의·selector·폴더 구조(`hub/`, `spoke/`)의 최종 소스는
`eks-practice-devops-manifest` 저장소의 `argocd/applicationsets/eks-addons/{hub,spoke}/`와
`argocd/CLAUDE.md`다. 이 저장소(Terraform)는 IAM만 관리하고 hub/spoke 배포 여부 자체를
결정하지 않으므로, 위 표는 그 저장소 구조를 요약 반영한 것이며 실제 변경은 그쪽 저장소가
우선한다.

### Secrets Store CSI Driver 대신 External Secrets Operator를 쓰는 이유 (2026-07-02 결정)

이 프로젝트는 Secrets Store CSI Driver + ASCP를 사용하지 않는다. 두 방식을 비교한 결과:

- **Secrets Store CSI Driver**: 대상 Pod의 볼륨에 시크릿을 파일로 마운트하는 방식. 앱이 파일시스템에서 값을 읽어야 하고, 자동 갱신(polling)이 있어도 K8s Secret 오브젝트로 변환하려면 `syncSecret` 기능을 별도로 켜야 한다.
- **External Secrets Operator**: SSM Parameter Store/Secrets Manager 값을 K8s Secret으로 직접 동기화한다. ArgoCD repo-creds처럼 K8s Secret 형태 자체가 필요한 대상(Helm values, 컨트롤러가 기대하는 Secret 라벨 규칙 등)에 바로 맞고, `refreshInterval`로 갱신 주기를 세밀하게 제어할 수 있다.

이 프로젝트가 다루는 민감 정보(ArgoCD admin 패스워드, GitHub App 인증 정보 등)는 전부 K8s Secret 형태로 소비되므로 ESO가 목적에 더 부합한다. 두 도구를 동시에 운영하면 시크릿 접근 경로가 두 갈래로 나뉘어 운영 복잡도만 늘어나므로, ESO 하나로 통일한다.

> ArgoCD repo-creds(`kubernetes_secret_v1/argocd-github-app-repo-creds`)가
> Terraform 소관인 이유는 애드온별 사유가 아니라 아래 "GitOps 관리 경계" 원칙에 따른 것이다.
> **ESO(ExternalSecret)조차 거치지 않고 Terraform이 SSM 값을 직접 읽어 평범한 K8s Secret으로
> 만든다** — ExternalSecret/ClusterSecretStore는 ESO가 설치하는 CRD라, ESO 자신도 GitOps로
> 이관되면 "ArgoCD 부트스트랩 → ESO 필요 → ESO도 ArgoCD가 sync해야 함 → 다시 ArgoCD 부트스트랩
> 필요"라는 순환이 생기기 때문이다(아래 표의 두 번째 행 참조).

---

## 오토스케일러 이원화와 노드 배치 규칙

### 결정: Karpenter와 Cluster Autoscaler를 함께 쓴다

일반적으로 두 오토스케일러는 동시 운영을 권하지 않지만, 이 프로젝트는 **시스템 Managed Node
Group(MNG)도 확장 가능한 구조로 만들기 위해 CA를 도입한다.**

시스템 MNG는 Terraform이 `min/max/desired_size`를 고정값으로 관리하는 정적 그룹이고,
Karpenter는 ASG를 전혀 사용하지 않으므로 이 노드 그룹을 확장 대상으로 보지 않는다. 애드온이
늘어 pod 슬롯이 부족해져도 스스로 늘어날 수단이 없다는 뜻이다. CA를 이 노드 그룹에만 스코프해
그 구멍을 메운다.

### 충돌 메커니즘 — 무엇이 겹치면 깨지는가

두 오토스케일러 모두 **Pending Pod**를 트리거로 동작한다. 하나의 Pod가 양쪽 모두의 스케일업
후보가 되면 CA는 MNG의 ASG를, Karpenter는 NodeClaim을 각각 늘려 **노드가 이중으로 뜬다.**
그 뒤 한쪽이 비면 축소 판단이 따로 돌아 노드가 붙었다 떨어졌다 하는 상태가 된다.

경계를 가르는 것은 오토스케일러 설정이 아니라 **Pod 쪽 스케줄 제약**이다. 그리고 여기서
taint/toleration만으로는 부족하다:

> **toleration은 허가지 강제가 아니다.** `CriticalAddonsOnly` toleration을 가진 시스템 애드온
> Pod는 "시스템 노드에도 뜰 수 있다"는 뜻일 뿐이며, taint가 없는 Karpenter general NodePool에도
> 그대로 스케줄된다. 실제로 ArgoCD 파드가 시스템 노드 포화 시점에 Karpenter 노드로 새어나갔다가
> 그 노드가 Underutilized로 disrupt되며 재배치된 사례가 있다.

### 분리 규칙 — 3계층을 모두 갖춘다

| 계층 | 수단 | 정의 위치 | 이 계층이 막는 것 |
|------|------|-----------|------------------|
| 1. 시스템 노드 진입 차단 | `CriticalAddonsOnly=true:NoSchedule` taint + `role=system` 레이블 | `modules/eks/1.0.0/main.tf` (시스템 MNG) | 일반 워크로드가 시스템 노드에 들어오는 것 → CA가 일반 워크로드 Pending에 반응하지 않는다 |
| 2. 시스템 애드온 고정 | `tolerations: CriticalAddonsOnly` **+** `nodeAffinity: role In [system]` (required) | devops-manifest 각 차트 `values-override.yaml` / ArgoCD 자신은 `modules/eks-addons/2.0.0/locals.tf` | 시스템 애드온이 Karpenter 노드로 새는 것 → Karpenter가 시스템 애드온 Pending에 반응하지 않는다 |
| 3. Karpenter 자기 배치 | `nodeAffinity: karpenter.sh/nodepool DoesNotExist` + `CriticalAddonsOnly` toleration | Karpenter 차트 upstream 기본값 | Karpenter 컨트롤러가 자기가 만든 노드 위에 뜨는 것 |

**규칙: 시스템 노드에서 돌아야 하는 컴포넌트를 추가할 때 toleration만 넣지 않는다.
`role=system` nodeAffinity(required)를 반드시 함께 넣는다.** 둘 중 하나만 있으면 2계층이
성립하지 않아 그 컴포넌트가 곧바로 충돌 지점이 된다.

Karpenter 컨트롤러는 3계층으로 `role=system`을 명시하지 않지만, Karpenter 노드를 배제하고 나면
남는 노드가 시스템 MNG뿐이라 결과적으로 동일한 배치가 된다.

### 현재 적용 현황

`role=system` nodeAffinity(required) + `CriticalAddonsOnly` toleration이 모두 걸려 있는 대상:
LBC, ExternalDNS, Cluster Autoscaler, External Secrets, KEDA, kube-state-metrics,
Metrics Server, OpenTelemetry Operator, Argo Rollouts, ArgoCD Image Updater, ArgoCD(+redis-ha).

Bootstrap 애드온 3종(`coredns` / `aws-ebs-csi-driver` / `cert-manager`)도 각 환경
`eks/locals.tf`의 `*_configuration_values`로 동일한 강제를 받는다. 이 3종은 `aws_eks_addon`으로
설치되어 devops-manifest(ArgoCD)의 관리 범위 밖이라, values-override가 아니라 Terraform에서
주입해야 한다. 주입 경로는 애드온마다 다르다:

| 애드온 | 경로 | 기본값 병합 |
|--------|------|------------|
| `coredns` | 최상위 `affinity` | 필요 — 기본값에 os/arch required nodeAffinity + replica 분산 podAntiAffinity가 있다 |
| `aws-ebs-csi-driver` | `controller.affinity` | 필요 — 기본값에 compute-type preferred nodeAffinity + podAntiAffinity가 있다 |
| `cert-manager` | 최상위 + `webhook.affinity` + `cainjector.affinity` | 필요 — 3곳 모두 기본값에 os/arch required nodeAffinity + `compute-type NotIn hybrid`가 있다 |

**`affinity`는 통째로 교체되는 필드다.** `role=system`만 넣으면 위 기본값이 사라진다 — CoreDNS는
replica 분산이 깨져 2개가 같은 노드에 몰릴 수 있다. 기본값을 그대로 옮겨 적은 뒤 `role=system`을
더한다. 이때 **같은 `nodeSelectorTerm`의 `matchExpressions`에 넣어야 한다** — term끼리는 OR로
평가되므로 별도 term으로 두면 제약이 오히려 느슨해진다.

기본값은 `aws eks describe-addon-configuration --addon-name <name> --addon-version <ver>`의
`configurationSchema`에서 각 필드의 `default`로 확인한다. 애드온 버전을 올릴 때 기본값이 바뀌면
여기 옮겨 적은 값도 함께 갱신해야 한다 — 스키마상 `affinity`는 자유 형식 객체(`type: ["object","null"]`)라
구조를 검증해주지 않는다.

### 이 강제가 만드는 운영상 결과 3가지

배치를 시스템 노드로 고정하면 아래가 따라온다. 셋 다 설계 의도의 부산물이라 알고 있어야 한다.

**1. CA의 스케일업 트리거는 Pending Pod뿐이고, 그 신호를 못 보는 구간이 있다.**
CA는 `requests`를 기준으로 판단한다. 그런데 `role=system`으로 고정된 애드온 중 requests가 설정된
것은 일부(metrics-server, KEDA, otel-operator 등)뿐이고 LBC·ExternalDNS·ESO·Karpenter·CA 자신·
kube-state-metrics·argo-rollouts 등 다수가 requests 미설정(BestEffort)이다. 이들의 실사용량은
스케줄러도 CA도 보지 못한다. 따라서 **"노드가 꽉 차서 신규 Pod가 Pending"이면 CA가 확장하지만,
"기존 Pod가 메모리 압박으로 evict/OOM"이면 requests 기준으로는 여전히 자리가 남아 보여 CA가
아무것도 하지 않는다.** 시스템 노드에 애드온을 추가할 때는 requests를 명시하는 편이 CA가 볼 수
있는 신호를 남긴다.

**2. Prefix Delegation이 allocatable 메모리를 깎는다.**
kubelet은 `11Mi × max_pods`를 예약한다. Prefix Delegation으로 `max_pods`가 17 → 110이 되면
t3.medium(4GiB) 기준 예약이 187Mi → 1210Mi로 늘어 **allocatable이 약 1GiB 줄어든다.**
pod 밀도 상한을 걷어낸 대가로 노드당 가용 메모리가 줄어든 것이라, 시스템 노드에 무엇을 더 얹을지
판단할 때 이 감소분을 반영해야 한다.

**3. CA 확장은 사실상 단방향이 된다.**
CA의 `--skip-nodes-with-system-pods` 기본값이 `true`라, kube-system 네임스페이스의 Deployment
Pod가 있는 노드는 축소 대상에서 제외된다. coredns·ebs-csi-controller·cert-manager가 전부
kube-system이므로, CA가 시스템 MNG를 2~3대로 늘린 뒤에는 **되돌아오지 않는다.** 축소가 필요하면
CA `extraArgs`를 조정해야 한다.

---

> **스키마를 읽을 때 `$ref`를 반드시 따라가야 한다.** 애드온마다 `default`를 놓는 위치가 다르다.
> coredns/ebs-csi는 속성에 `default`가 직접 붙어 있지만, cert-manager는 속성이
> `{"$ref": "#/definitions/helm-values.affinity"}`뿐이고 실제 `default`는 그 정의 안에 있다.
> `properties.affinity.default`만 읽으면 `null`로 보여 "기본값이 없다"고 오판하게 된다.
>
> 표기 방식도 애드온마다 제각각이다 — coredns/ebs-csi의 `default`는 `{"affinity": {...}}`처럼
> 필드명이 한 번 더 감싸여 나오고, cert-manager는 `nodeAffinity` 래퍼가 빠진 채
> `{"requiredDuringScheduling...": {...}}`로 나온다. 실제로 전달할 값은 어느 쪽이든 Kubernetes
> PodSpec의 `affinity` 스키마(`{nodeAffinity: {...}}`)를 따른다.

---

## GitOps 관리 경계 (부트스트랩 순환 의존성)

이 프로젝트의 서비스 매니페스트(catalog/order/gateway 등)는 ArgoCD가
`eks-practice-devops-manifest` 저장소를 sync해서 GitOps로 관리한다. 하지만 **ArgoCD 자신이
그 sync 루프에 들어가기 위해 필요한 리소스**는 GitOps로 관리할 수 없다 — ArgoCD가 아직
그 저장소를 sync할 수 없는 시점에 필요한 리소스이기 때문이다(순환 의존성).

**판단 기준 (애드온마다 재해석하지 않고 이 기준 하나로 판단한다)**:
"ArgoCD 자신의 부트스트랩에 필요한 리소스인가, 아니면 ArgoCD가 이미 sync 가능한 상태에서
배포하는 리소스인가?"

| 리소스 유형 | GitOps 관리 | 이유 |
|---|---|---|
| ArgoCD 자체 설치 (Helm) | 불가 → Terraform | ArgoCD가 자기 자신을 GitOps로 설치할 수 없음 |
| ArgoCD repo-creds (ArgoCD의 Git 인증정보) | 불가 → Terraform, **ESO도 우회** | ArgoCD가 devops-manifest 저장소 인증정보를 그 저장소 안에서 가져올 수 없음. ExternalSecret/ClusterSecretStore도 ESO가 설치하는 CRD라 ESO를 GitOps로 이관하면 이 리소스도 똑같이 순환에 걸린다 — 그래서 `kubernetes_secret_v1` + `data "aws_ssm_parameter"`로 ESO 자체를 우회한다 |
| 개별 서비스 리소스 (Deployment, 그 서비스가 쓰는 ExternalSecret 등) | 가능 → devops-manifest(GitOps) | ArgoCD가 이미 sync 가능한 시점 이후에 배포되는 리소스 |
| AWS 리소스 (IAM Role, ACM, Route53, SSM Parameter 값 등) | 해당 없음 → Terraform | K8s 오브젝트가 아니므로 애초에 GitOps(ArgoCD) 범위 밖 |

새 애드온·리소스를 추가할 때도 이 표의 첫 두 행에 해당하는지만 확인하면 되고,
애드온별로 별도 GitOps 불가 사유를 문서화할 필요는 없다.

---

## IAM 전략

애드온 설치 방식에 따라 IAM 연동 방식이 다르다.

| 설치 방식 | IAM 전략 | 이유 |
|-----------|----------|------|
| `aws_eks_addon` (Bootstrap) | **Pod Identity** | blueprints 미사용 → Pod Identity 우선 |
| Helm (blueprints) | **IRSA** | blueprints 모듈이 IRSA만 지원 (Pod Identity 미지원) |
| Helm (non-blueprints, 손코드 IAM) | **Pod Identity** | blueprints 미사용 → Pod Identity 우선 (아래 "기본 원칙" 참조) |

**기본 원칙: Pod Identity를 사용할 수 있는 경우 항상 Pod Identity를 우선한다.** AWS가
IRSA의 후속으로 권장하는 방식이고(OIDC Provider 불필요, `sts:AssumeRoleWithWebIdentity`
없이 `pods.eks.amazonaws.com` 서비스 principal로 단순화), Role ARN을 Helm values
annotation 경로로 직접 주입할 필요가 없어 IRSA 대비 배관(plumbing)이 단순하다. **IRSA는
Pod Identity를 지원하지 않는 도구(blueprints 등)를 쓸 수밖에 없을 때만 예외로 허용한다** —
"Helm으로 설치한다"는 사실 자체가 IRSA를 정당화하지 않는다. `gitops-bridge-dev/gitops-bridge/helm`로
설치하는 ArgoCD Hub Controller(root `gitops-bridge-irsa.tf`)가 이 원칙의 실제 예시다 —
아래 "ArgoCD Hub Controller" 절 참조.

blueprints의 Pod Identity 미지원 근거:
github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/289 — Closed as Not Planned

### EBS CSI Driver (Bootstrap — modules/eks) — Pod Identity

`pods.eks.amazonaws.com` trust policy로 IAM Role을 생성하고
`aws_eks_pod_identity_association`으로 연결한다.

```hcl
# module.eks 호출 전에 선언. Pod Identity는 OIDC 불필요 → 순환 의존성 없음.
resource "aws_iam_role" "ebs_csi" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

module "eks" {
  source = "terraform-aws-modules/eks/aws"
  ...
  addons = {
    aws-ebs-csi-driver = {
      addon_version = var.addon_versions.ebs_csi_driver
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }
}
```

### Helm 전용 addon (LBC, ExternalDNS, Karpenter) — IRSA

blueprints 모듈에 `oidc_provider_arn`을 전달하면 IAM Role 생성을 내부에서 자동 처리한다.
blueprints가 IRSA를 강제하므로 이 경우에만 IRSA를 사용한다.

**GitOps Bridge 이관 완료 이후로는 Helm values `serviceAccount.annotations` 주입도
blueprints가 하지 않는다** — blueprints는 이제 이 IAM Role만 만들고 Helm release 자체를
설치하지 않기 때문이다(`modules/eks-addons/2.0.0`, `create_kubernetes_resources` 하드코딩
`false`). 이 IAM Role ARN을 실제 Helm values에 주입하는 건 ArgoCD의 GitOps Bridge
메타데이터 브릿지다 — Terraform이 cluster Secret의 `metadata.annotations`에 이 ARN을
기록해두면, devops-manifest의 ApplicationSet이 `{{metadata.annotations.xxx}}`로 읽어
`helm.parameters`에 주입한다(`docs/gitops-principles.md`, `modules/eks-addons/2.0.0/CLAUDE.md`
참조).

### ArgoCD Hub Controller (root `gitops-bridge-irsa.tf`) — Pod Identity

`argocd-application-controller`가 dev/prd(다른 AWS 계정) spoke Role을 `sts:AssumeRole`하기
위한 Hub 자신의 identity(`monitoring/.../eks-addons/gitops-bridge-irsa.tf`의
`aws_iam_role.argocd_application_controller`)는 blueprints가 아니라 손코드로 만든 Role이라
위 "기본 원칙"에 따라 Pod Identity(`aws_eks_pod_identity_association`)를 사용한다 — `argo-cd`
Helm chart의 `controller.serviceAccount.annotations` 경로(IRSA annotation)는 쓰지 않는다.

Pod Identity association의 Role은 클러스터와 같은 계정에만 있으면 되므로(이 Role은
monitoring 자신의 Role) 이 조건을 만족한다. Hub가 spoke 계정 Role을 assume하는 크로스 계정
체인은 Hub Role의 inline policy(`aws_iam_role_policy.argocd_hub_assume_spokes`)가 별도로
담당하며, Hub 자신의 identity 부여 방식(IRSA vs Pod Identity)과는 무관하다 — "spoke Role
ARN을 알아야 assume할 수 있다"는 요구사항은 크로스 계정 IAM의 본질이지 IRSA 특유의 제약이
아니다. spoke 쪽(`project/environments/{develop,production}/.../eks-addons/gitops-bridge-spoke-irsa.tf`)의
`aws_eks_access_entry`는 Hub Role이 아니라 spoke 자신이 소유하는 spoke Role의 ARN에 대해서만
걸려있으므로(원문: `principal_arn = aws_iam_role.gitops_bridge_spoke.arn`), Hub의 identity
부여 방식 변경은 spoke 쪽 access entry에 전혀 영향을 주지 않는다.

### 애플리케이션 워크로드 (order 등) — Pod Identity

애드온이 아닌 서비스 Pod에도 위 "기본 원칙"이 그대로 적용된다. IAM 리소스는 그 AWS 리소스를
소유한 root module이 함께 관리한다 — 예: order 서비스의 SQS 발행 권한은 큐를 만드는
`project/environments/develop/ap-northeast-2/order/sqs/`가 `iam-pod-identity.tf`로 소유한다.
큐 ARN이 그 state에 있어 remote_state 왕복이 생기지 않는다.

Role만 만들고 `aws_eks_pod_identity_association`을 빠뜨리면 Pod에 자격증명 env가 아예
주입되지 않는다. 노드는 IMDS hop limit 1이라 인스턴스 역할 폴백도 없어, SDK가 `NoCredentials`로
실패한다(2026-08-05 dev 클러스터 실측).

자격증명 env는 admission 시점에 주입되므로 **association을 만든 뒤 대상 Pod을 재생성**해야
반영된다. association만 만들고 Pod을 그대로 두면 아무 변화가 없다.

기존 워크로드를 IRSA에서 옮겨오는 경우, association 생성만으로 전환이 완결된다. SA에 IRSA
annotation이 남아 있어도 **EKS Pod Identity webhook이 Pod Identity를 우선**해 IRSA
env(`AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`)를 주입하지 않는다 — annotation 제거는
전제 조건이 아니라 사후 정리다. 근거:
[AWS Containers Blog](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/)
— *"The EKS Pod Identity webhook gives preference to EKS Pod Identity over IRSA, when it notices
roles setup with both trusted entities."* (2026-08-05 dev 클러스터에서 실측 확인)

---

## 버전 관리

### Bootstrap 애드온 (EKS 관리형)

`most_recent = true` 사용 금지. `addon_version`을 반드시 명시한다.

```bash
aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name aws-ebs-csi-driver \
  --region ap-northeast-2 \
  --query 'addons[].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion' \
  --output text
```

버전 값은 `environments/.../eks/locals.tf`의 `eks.addon_versions`에서 관리한다.

### Helm 애드온

`version`을 명시하고 `repository`를 고정한다. `latest` 또는 버전 미지정 금지.

버전 값은 `environments/.../eks-addons/locals.tf`의 `eks_addons`에서 관리한다.

---

## 업그레이드 절차

### Bootstrap 애드온

1. 신규 버전 조회: `aws eks describe-addon-versions --kubernetes-version <k8s-ver> --addon-name <name>`
2. `defaultVersion: true` 버전 확인
3. `environments/.../eks/locals.tf`의 `addon_versions` 값 수정
4. `terraform plan` 검토 → `terraform apply`

### Helm 애드온

1. `helm repo update`
2. Artifact Hub / GitHub Releases에서 최신 stable 버전 확인
3. `environments/.../eks-addons/locals.tf`의 chart version 값 수정
4. `terraform plan` 검토 → `terraform apply`
