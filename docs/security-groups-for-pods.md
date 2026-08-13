# Security Groups for Pods (SGP) 운영 정책

Pod 단위로 보안 그룹을 적용하는 기능이다. 이 문서는 **이 프로젝트가 SGP를 어떻게 운영하는지**와
**지켜야 할 제약**을 기술한다.

## 왜 쓰는가

VPC CNI 기본 동작에서 Pod는 노드 ENI의 보조 IP를 나눠 쓴다. 보안 그룹은 ENI에 붙으므로
**같은 노드의 모든 Pod가 같은 SG를 공유**한다. "이 Pod만 특정 목적지 접근 허용" 같은 통제가
성립하지 않는다.

SGP는 매칭된 Pod에 전용 브랜치 ENI를 배정해 Pod 단위 SG 적용을 가능하게 한다. 특정 Pod에만
데이터스토어·내부 API 접근을 허용하고 나머지는 차단해야 할 때 쓴다.

## 동작 구조

`ENABLE_POD_ENI=true`일 때:

1. 노드에 트렁크 ENI(`aws-k8s-trunk-eni`) 1개가 붙고, VPC Resource Controller(EKS 관리 컴포넌트)가
   `vpc.amazonaws.com/pod-eni`를 extended resource로 광고한다.
2. Mutating webhook이 `SecurityGroupPolicy`에 매칭되는 Pod에 `vpc.amazonaws.com/pod-eni: 1`을
   주입한다 → 스케줄러가 브랜치 ENI 여유가 있는 노드로만 배치한다.
3. Pod마다 브랜치 ENI(`aws-k8s-branch-eni`)가 생성돼 트렁크에 연결되고, 여기에 Pod SG가 붙는다.

`Insufficient vpc.amazonaws.com/pod-eni`로 Pending에 걸리는 것은 IP 부족이 아니라 이 extended
resource 부족이다.

**브랜치 ENI는 노드 SG를 상속하지 않는다.** 어느 모드를 쓰든 Pod SG에 없는 통신은 열리지 않으며,
차이는 노드 SG를 **함께** 평가하느냐(`standard`)  **대체**하느냐(`strict`)다.

---

## enforcing mode — `standard`를 쓴다

| | `strict` (기본값) | **`standard` (채택)** |
|---|---|---|
| 적용 SG | 브랜치 ENI(Pod SG)만 | **Pod SG + 노드 SG** |
| SNAT | 비활성 | VPC 외부행은 노드 IP로 SNAT |
| Pod 단위 접근 통제 | 가능 | **가능 (동일)** |
| Pod 단위 **egress** 통제 | VPC 안팎 모두 | **VPC 내부만** |
| 노드 내 Pod 간 통신 | VPC 경유 | 로컬 |
| kubelet probe | Pod SG 인바운드 + `DISABLE_TCP_EARLY_DEMUX` 필요 | **추가 설정 불필요** |

### 채택 이유 — EKS Pod Identity

**`strict`에서는 Pod Identity가 동작하지 않는다.** Pod Identity Agent는 링크로컬 주소
(`169.254.170.23`)로 자격증명을 제공하는데, `strict`는 모든 아웃바운드를 브랜치 ENI로 몰아
VPC로 내보내므로 그 주소에 도달할 수 없다. 링크로컬은 VPC 라우팅 대상이 아니다.

**SG 규칙으로는 해결되지 않는다.** Pod SG에 `169.254.170.23/32`를 명시적으로 허용해도 결과가
같다 — 방화벽이 막는 것이 아니라 **경로 자체가 없다.** 유일한 해법이 `standard`다.

이 프로젝트의 `order`는 SQS 발행에 Pod Identity를 쓴다. `strict`를 유지하면 SGP를 그 워크로드로
확장하는 순간 자격증명이 끊기므로, 처음부터 `standard`를 기본으로 둔다.

> kubelet probe가 깨지는 것과 뿌리는 같지만(둘 다 노드 로컬 경로 의존) **막히는 계층이 달라
> 해법이 갈린다.** probe는 L3까지 도달한 뒤 SG가 막는 것이라 규칙 추가로 해결되고, Pod Identity는
> 애초에 L3로 갈 수 없어 모드를 바꾸는 것 외에 방법이 없다.

### 무엇을 포기하는가

**Pod 단위 접근 통제는 그대로다.** 브랜치 ENI도 그대로 붙고, "라벨이 있는 Pod만 이 데이터스토어
접근" 같은 통제는 두 모드가 동일하게 동작한다.

포기하는 것은 **VPC 밖으로 나가는 트래픽의 Pod 단위 통제**뿐이다. `standard`에서 SNAT은 VPC를
벗어날 때만 일어나고, 그때는 노드 SG가 적용되어 Pod별 차등이 불가능하다.

- VPC 안(데이터스토어, 다른 Pod, 인터페이스 엔드포인트) → **Pod SG 적용**
- VPC 밖(인터넷, NAT 경유 리전 서비스) → **노드 SG 적용, Pod SG 무시**

즉 `standard`에서는 "이 Pod만 인터넷 차단"을 만들 수 없다. 그 통제가 필요해지면 NetworkPolicy 등
다른 계층을 검토한다.

### `strict`가 필요해질 때

Pod 단위 egress 차단이 반드시 필요하다면 `strict`로 올릴 수 있다. 단 아래를 함께 확인한다.

| 확인 | 내용 |
|---|---|
| Pod Identity | 해당 워크로드가 쓰지 않아야 한다 |
| `DISABLE_TCP_EARLY_DEMUX` | `init.env`에 추가 필요 |
| Pod SG 인바운드 | probe 포트를 노드 SG로부터 허용 필요 |
| `externalTrafficPolicy: Local` + instance target | 미지원 |
| NodeLocal DNSCache | 미지원 |
| NetworkPolicy 병행 | 미지원 |

**모드 변경은 신규 Pod에만 반영된다.** 기존 Pod 전체 재생성이 필요하다.

### `AWS_VPC_K8S_CNI_EXTERNALSNAT`은 켜지 않는다

Best Practices는 이 설정을 *"Pods that require access the internet"* 전제로 권고하는데, 이
프로젝트의 Pod SG는 `0.0.0.0/0` egress를 두지 않아 해당하지 않는다. 반면 이 설정은 **클러스터
전역**이라 SGP를 쓰지 않는 Pod의 egress 경로까지 바꾼다. 얻는 것 없이 영향 범위만 넓어진다.

---

## 설정

### vpc-cni 애드온 (`{env}/shared/eks/locals.tf`)

```hcl
vpc_cni_configuration_values = jsonencode({
  env = {
    ENABLE_PREFIX_DELEGATION          = "true"
    ENABLE_POD_ENI                    = "true"
    POD_SECURITY_GROUP_ENFORCING_MODE = "standard"
  }
})
```

`POD_SECURITY_GROUP_ENFORCING_MODE`는 enum이 아니라 **자유 문자열**이라 오타를 스키마가 잡지
않는다. 값이 틀리면 조용히 기본값(`strict`)으로 동작한다 — 적용 여부는 클러스터에서 확인한다.

```bash
kubectl get ds aws-node -n kube-system \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E "POD_ENI|ENFORCING"
```

> `strict`로 올릴 때 필요한 `DISABLE_TCP_EARLY_DEMUX`는 `env`가 아니라 **`init.env`** 아래다.
> 스키마상 `Env`는 `additionalProperties: false`라 잘못된 위치에 넣으면 애드온 업데이트가 거부된다.

### 클러스터 IAM 정책

트렁크/브랜치 ENI를 만드는 주체는 컨트롤 플레인의 VPC Resource Controller다. **노드 Role이 아니라
클러스터 Role**에 `AmazonEKSVPCResourceController`가 필요하다. 업스트림 EKS 모듈은
`AmazonEKSClusterPolicy`만 붙이므로 `modules/eks`가 보충한다.

이 정책은 별도 토글 없이 **`ENABLE_POD_ENI` 값에서 파생**된다(`modules/eks/1.0.0/main.tf` 상단
local). 토글을 따로 두면 "CNI는 켰는데 IAM은 안 붙은" 상태가 만들어지고, 그 증상이
`Insufficient vpc.amazonaws.com/pod-eni` 하나로만 나타나 원인 추적이 어렵다.

### `RESERVED_ENIS=1` — Karpenter 설정에 반드시 함께 간다

트렁크 ENI가 인스턴스 ENI 슬롯 하나를 영구 점유하는데 `maxPods` 계산식이 이를 모른다. 설정하지
않으면 실제보다 크게 잡혀 IP 고갈이 난다.

```
maxPods = (ENI 개수 - reservedENIs) × (ENI당 IP - 1) + 2
c5.large : (3-1)×9+2 = 20      (미설정 시 29)
```

**신규 노드에만 반영된다** — 설정이 먹었는지 보려면 새로 뜬 노드를 봐야 한다.

---

## 필수 부수 설정 — DNS 하나

`standard`는 Pod SG와 **노드 SG를 함께** 평가하므로, 노드 SG에 이미 있는 규칙(kubelet probe,
컨트롤 플레인 통신 등)이 그대로 살아 있다. `strict`와 달리 대부분의 경로에 추가 설정이 필요 없다.

**단 하나 예외가 DNS다.**

| 방향 | 어디에 무엇을 | 빠뜨리면 |
|---|---|---|
| **Pod → CoreDNS** | **노드 SG**: `53 tcp/udp ← Pod SG` | 이름 해석 실패 |

CoreDNS는 노드 ENI를 쓰는데 노드 SG의 DNS 규칙은 **자기 자신(self)만** 허용한다. Pod SG를 단
브랜치 ENI는 그 조건에 맞지 않아 별도 규칙이 필요하다. `eks-addons/pod-security-groups.tf`가
만든다.

> **DNS 실패는 다른 실패를 가린다.** 이름 해석이 안 되면 모든 연결이 타임아웃으로 보여
> "네트워크가 통째로 막혔다"로 오진하기 쉽다. **진단할 때는 IP로 먼저 확인한다.**

### Pod SG에 필요한 egress

`standard`에서도 **VPC 내부 목적지는 Pod SG가 통제**한다. 워크로드가 쓰는 목적지를 열어야 한다.

```
53 tcp/udp → VPC CIDR      # CoreDNS
<목적지 포트> → VPC CIDR    # 데이터스토어·내부 API 등
```

VPC 밖으로 나가는 트래픽은 노드 SG가 적용되므로 Pod SG에 열 필요가 없다.

### 클러스터 SG를 SGP에 넣지 않는다

`eks-cluster-sg-*`는 egress가 `0.0.0.0/0`이다. Pod ENI에 붙이는 순간 **Pod SG의 egress 통제가
합집합으로 무력화**된다. 컨트롤 플레인 통신이 필요하면 SG를 붙이지 말고 **필요한 방향·포트만
규칙으로** 연다 — "SG를 ENI에 붙이는 것"과 "SG를 규칙의 출발지로 참조하는 것"은 다르며, 참조는
egress에 영향이 없다.

### 오진하기 쉬운 것

`kubectl exec`/`logs`는 **kubelet 경유라 Pod SG와 무관하다.** SGP 설정이 잘못돼도 정상 동작하므로,
"exec는 되니 네트워크 문제는 아니다"로 판단하면 진단이 어긋난다.

---

## 인스턴스 타입 제약

> No instance types in the `t` family are supported. — EKS User Guide

`limits.go`(amazon-vpc-resource-controller-k8s)의 `IsTrunkingCompatible: true`가 확정 기준이다.

| 노드 집합 | 인스턴스 | 브랜치 ENI 한도 |
|---|---|---|
| 시스템 MNG | `t3.medium` / `t3a.medium` | **불가** |
| Karpenter (c/m/r, gen>2) | `*.large` | 9 |
| | `*.xlarge` | 18 |
| | `c5.2xlarge` | 38 |

**SGP Pod는 Karpenter 노드에만 뜬다.** 시스템 노드에 강제 배치하면 Pending에 걸린다 — 노드 SG로
조용히 폴백하지 않고 명시적으로 실패한다(fail-closed).

> Karpenter NodePool의 `instance-category`에 `t`를 추가하면 이 전제가 조용히 깨진다. SGP Pod만
> Pending에 걸려 NodePool 변경과 연결짓기 어렵다.

**sub-large(`*.medium` 이하)는 쓸 수 없다.** ENI가 2개뿐이라 `RESERVED_ENIS=1`을 빼면 pods가 5로
떨어져 데몬셋 바닥값도 못 채운다. Karpenter가 `no instance type which had enough resources`로
거부하므로 별도 하한 설정은 불필요하다. Graviton 자체는 트렁킹을 지원한다(`c6g.large` 정상).

---

## SG 설계 원칙

### 목적지 SG가 Pod SG를 받아줘야 한다

VPC 안에서 Pod SG는 이 Pod가 말을 거는 **모든 목적지**에서 출발지 신원이 된다. egress를 여는
것만으로는 부족하고 **목적지 쪽 SG도 이 SG를 인바운드로 허용**해야 통신이 성립한다. 노드 SG의
DNS 규칙(`53 ← Pod SG`)이 이 원칙의 적용이다.

노드 SG가 `self` 참조로만 열어둔 규칙은 브랜치 ENI에 적용되지 않는다는 점이 핵심이다 — 노드
기준으로 이미 열려 있어 보여도 Pod SG를 출발지로 하는 규칙이 따로 필요할 수 있다.

### Pod SG의 egress는 목적지 SG를 참조하지 않는다

Pod SG egress에서 목적지 SG를 참조하면 두 root가 서로를 참조해 순환이 생긴다. **egress는 VPC
CIDR + 포트로 두고**, 실제 통제는 목적지 SG의 inbound에서 한다. egress가 다소 넓어도 목적지가
받아주지 않으면 통신이 성립하지 않으므로 목적은 달성된다.

### 노드 SG가 얽히는 규칙은 클러스터 lifecycle 쪽에 둔다

`53 ← Pod SG`(DNS)와 `probe ← 노드 SG`는 노드 SG를 참조하므로 클러스터와 함께 생성·삭제돼야
한다. `{env}/shared/eks-addons/pod-security-groups.tf`가 소유한다.

### SG는 워크로드별로 나눈다

여러 서비스가 하나의 Pod SG를 공유하면:

- 한 서비스에 필요한 규칙이 다른 서비스에도 적용돼 통제가 느슨해진다
- ALB 타깃일 때 LBC가 포트를 **범위로 통합**한다(80과 8080을 쓰면 `80-8080`이 열린다)

---

## ALB 타깃일 때

LBC는 클러스터당 하나의 **공유 백엔드 SG**(`k8s-traffic-<cluster>-*`)를 모든 ALB에 붙이고, 그것을
출발지로 하는 인바운드를 타깃 SG에 넣는다. Pod SG가 알아야 하는 출발지는 이 하나로 고정되며,
이 규칙 하나가 **헬스체크까지 커버**한다(probe와 달리 별도 규칙이 불필요).

### 지켜야 할 두 가지

**① Pod에 SG가 2개 이상이면 하나에 클러스터 태그를 붙인다**

```
kubernetes.io/cluster/<cluster_name> = shared     ← Pod SG(AWS 리소스)에 부여
```

SG가 1개면 불필요하다. 2개 이상인데 태그가 없으면 LBC가 대상을 특정하지 못해 **기존 규칙을
회수하고** 멈춘다 — 살아있던 인그레스가 끊긴다. 태그를 부여해도 **LBC 파드를 재시작해야** 반영된다
(SG 태그를 캐싱한다).

**② `security-groups`를 지정하면 `manage-backend-security-group-rules`를 함께 붙인다**

```yaml
alb.ingress.kubernetes.io/security-groups: sg-xxxx
alb.ingress.kubernetes.io/manage-backend-security-group-rules: "true"   # 필수
```

`security-groups`를 지정하면 백엔드 SG 관리가 **기본 OFF**가 된다. 이때 LBC는 백엔드 SG를 ALB에
붙이지도 않고 타깃 SG에 규칙도 넣지 않으며, **에러 로그조차 남기지 않는다.** ALB는 정상 생성되고
Pod도 Running인데 타깃만 `Target.Timeout`이 된다. 다른 Ingress가 열어둔 규칙에 편승할 수도 없다 —
백엔드 SG가 애초에 부착되지 않으므로 출발지가 맞지 않는다.

---

## 매니페스트 연동

`SecurityGroupPolicy`는 K8s 리소스라 devops-manifest(ArgoCD) 소관이고, SG는 AWS 리소스라 Terraform
소관이다. **SG ID를 매니페스트로 전달해야 한다.**

**SGP CR과 Pod를 같은 sync에서 배포하면 경쟁이 발생한다.** 주입은 admission 시점에만 일어나므로,
Pod가 SGP보다 먼저 생성되면 webhook이 매칭할 정책이 없어 브랜치 ENI가 붙지 않는다. Pod는 정상
Running이고 라벨도 붙어 있어 **겉보기로는 멀쩡하다.**

```bash
# 판별: 비어 있으면 주입되지 않은 것 → Pod 재생성으로 해소
kubectl get pod <name> -o jsonpath='{.spec.containers[0].resources.limits}'
```

기존 워크로드에 SGP를 나중에 적용할 때도 같은 이유로 재생성이 필요하다.

---

## teardown 주의

브랜치 ENI는 Pod 삭제 후 회수되며(약 1분), 잔존 ENI는 VPC/서브넷 삭제를 막는다. 트렁크 ENI는
노드와 함께 사라진다.

```bash
# Pod 삭제 후 잔존 확인
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=aws-k8s-branch-eni,aws-k8s-trunk-eni" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status}"
```

`terminationGracePeriodSeconds`는 기본값(30)을 쓴다. AWS 문서는 `0`이면 ENI가 누수된다고 서술한다.

---

## 참고

- [Assign security groups to individual Pods — EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/security-groups-for-pods.html)
- [Security Groups Per Pod — EKS Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/sgpp.html)
- [Pod Identity Considerations](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [Security Group Management — AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/security_groups/)
