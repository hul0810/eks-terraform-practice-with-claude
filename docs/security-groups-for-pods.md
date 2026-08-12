# Security Groups for Pods (SGP) 설계

## 무엇을 해결하는가

VPC CNI 기본 동작에서 Pod는 노드 ENI의 보조 IP를 나눠 쓴다. 보안 그룹은 ENI에 붙으므로
**같은 노드의 모든 Pod가 같은 SG를 공유**한다. "이 Pod만 RDS 접근 허용" 같은 통제가 성립하지 않는다.

SGP는 Pod마다 전용 ENI(브랜치 ENI)를 배정해 Pod 단위로 SG를 적용한다.

## 동작 원리

`ENABLE_POD_ENI=true`를 켜면:

1. ipamd가 트렁킹 지원 인스턴스에 라벨을 붙이고, **VPC Resource Controller**(EKS가 관리하는
   컨트롤 플레인 컴포넌트)가 `vpc.amazonaws.com/pod-eni`를 extended resource로 광고한다.
2. 노드에 트렁크 ENI(`aws-k8s-trunk-eni`) 1개가 붙고, Pod마다 브랜치 ENI(`aws-k8s-branch-eni`)가
   생성돼 트렁크에 연결된다.
3. **Mutating webhook**이 `SecurityGroupPolicy`에 매칭되는 Pod에 `vpc.amazonaws.com/pod-eni: 1`
   요청을 자동 주입한다 → 스케줄러가 브랜치 ENI 여유가 있는 노드로만 배치한다.

Pod가 `Insufficient vpc.amazonaws.com/pod-eni`로 Pending에 걸리는 것은 IP 부족이 아니라
이 extended resource 부족이다.

> Deployment에 SGP를 가리키는 필드는 없다. `SecurityGroupPolicy`가 `podSelector`로 Pod를
> 고르는 셀렉터 방식이라, **워크로드 매니페스트는 손대지 않아도 된다.** 대신 라벨이 조인 키다.

---

## enforcing mode — `strict`를 쓴다

`POD_SECURITY_GROUP_ENFORCING_MODE`는 `strict`(기본값)와 `standard` 두 가지다.

| | `strict` | `standard` |
|---|---|---|
| 적용 SG | 브랜치 ENI(Pod SG)만 | Pod SG + 노드 SG |
| SNAT | 비활성 | VPC 외부행은 노드 IP로 SNAT |
| Pod 단위 egress 통제 | **가능** | VPC 내부만 가능 |
| 노드 내 Pod 간 통신 | VPC 경유 | 로컬 |

### 판단 기준: 목적지가 VPC CIDR 안인가

`standard`에서 SNAT은 **VPC를 벗어날 때만** 일어난다. 그래서:

- VPC 안(RDS, 다른 Pod, 인터페이스 엔드포인트) → Pod SG 적용
- VPC 밖(인터넷, NAT 경유 리전 서비스) → **노드 SG 적용, Pod SG 무시**

노드 SG는 노드 단위라 Pod별 차등이 불가능하다. 즉 `standard`에서는 "이 Pod만 인터넷 차단"을
만들 수 없다.

### `strict`를 선택한 이유

Pod SG가 ingress·egress를 온전히 통제하는 것이 SGP의 본래 취지이고, 이 프로젝트는 그 동작을
그대로 실습 대상으로 삼는다. AWS가 `standard`를 권하는 세 가지 상황
(`externalTrafficPolicy: Local` + instance target / NodeLocal DNSCache / NetworkPolicy 병행)에
현재 어느 것도 해당하지 않는다.

**대가**: `init.env.DISABLE_TCP_EARLY_DEMUX = "true"`가 반드시 따라온다. 없으면 kubelet이 브랜치
ENI 위 Pod에 TCP로 붙지 못해 **liveness/readiness probe가 전부 실패**한다. apply는 성공하고
런타임에서만 드러난다.

### `AWS_VPC_K8S_CNI_EXTERNALSNAT`은 켜지 않는다

Best Practices는 이 설정을 *"For Pods using security groups **that require access the
internet**"* 이라는 전제 아래 권고한다. 이 프로젝트의 Pod SG는 `0.0.0.0/0` egress를 두지 않아
그 전제에 해당하지 않는다. User Guide 쪽은 strict 모드 Pod의 인터넷 접근 조건으로 private
subnet + NAT Gateway만 요구하고 이 설정을 언급하지 않는다.

반면 이 설정은 **클러스터 전역**이라 SGP를 쓰지 않는 Pod의 egress 경로까지 바꾼다(VPC 피어링
건너편에 노드 IP 대신 Pod IP가 노출되는 등). 얻는 것 없이 영향 범위만 넓어지므로 켜지 않는다.

SGP Pod에 인터넷 egress를 열어야 할 때 함께 검토한다.

**`standard`로 되돌려야 할 때**: NetworkPolicy나 NodeLocal DNSCache를 도입하는 시점. 모드 변경은
**신규 Pod에만 반영**되므로 기존 Pod 전체 재생성이 필요하다.

---

## 설정 위치

`vpc-cni`는 EKS 관리형 애드온이라 `modules/eks`가 소유하고, 값은 환경 `eks/locals.tf`의
`vpc_cni_configuration_values`로 전달한다.

```hcl
env = {
  ENABLE_PREFIX_DELEGATION          = "true"
  ENABLE_POD_ENI                    = "true"
  POD_SECURITY_GROUP_ENFORCING_MODE = "strict"
  AWS_VPC_K8S_CNI_EXTERNALSNAT      = "true"
}
init = {
  env = { DISABLE_TCP_EARLY_DEMUX = "true" }
}
```

`DISABLE_TCP_EARLY_DEMUX`는 `env`가 아니라 **`init.env`** 아래다. 스키마상 `Env`는
`additionalProperties: false`라 잘못된 위치에 넣으면 애드온 업데이트가 거부된다.
`POD_SECURITY_GROUP_ENFORCING_MODE`는 enum이 아니라 자유 문자열이라 오타를 스키마가 잡아주지
않는다.

### 클러스터 IAM 정책

트렁크/브랜치 ENI를 실제로 만드는 주체는 컨트롤 플레인의 VPC Resource Controller다. **노드 Role이
아니라 클러스터 Role**에 `AmazonEKSVPCResourceController`가 필요하다. 업스트림 EKS 모듈은 표준
클러스터에 `AmazonEKSClusterPolicy`만 붙이므로 `modules/eks`가 보충한다.

이 정책은 별도 토글 없이 **`ENABLE_POD_ENI` 값에서 파생**된다(`modules/eks/1.0.0/main.tf` 상단
local). 토글을 따로 두면 "CNI는 켰는데 IAM은 안 붙은" 상태가 만들어지고, 그 증상이
`Insufficient vpc.amazonaws.com/pod-eni` 하나로만 나타나 원인 추적이 어렵다.

### 영향 범위 구분

| 설정 | 영향 |
|---|---|
| `POD_SECURITY_GROUP_ENFORCING_MODE` | SGP 매칭 Pod만 |
| `ENABLE_POD_ENI` | 트렁킹 가능 노드에 트렁크 ENI 부착 |
| `DISABLE_TCP_EARLY_DEMUX` | 클러스터 전역이나 branch ENI probe를 위한 완화 |
| `AWS_VPC_K8S_CNI_EXTERNALSNAT` | **클러스터 전역 — 모든 Pod의 egress 경로 변경** |

마지막 항목은 SGP를 쓰지 않는 기존 Pod에도 적용된다. Pod IP가 그대로 NAT Gateway까지 가게 되며,
VPC 피어링 건너편(OTel Gateway)으로 가는 트래픽도 노드 IP가 아닌 Pod IP를 달게 된다.

---

## 인스턴스 타입 제약 — t 계열 불가

> Security groups for Pods are supported by most Nitro-based instance families...
> **No instance types in the `t` family are supported.**
> — EKS User Guide

`limits.go`(amazon-vpc-resource-controller-k8s)의 `IsTrunkingCompatible: true` 여부가 확정 기준이다.

| 노드 집합 | 인스턴스 | 브랜치 ENI 한도 |
|---|---|---|
| 시스템 MNG | `t3.medium` / `t3a.medium` | **불가** |
| Karpenter (c/m/r, gen>2) | `*.large` | 9 |
| | `*.xlarge` | 18 |
| | `c5.2xlarge` | 38 |

**SGP Pod는 Karpenter 노드에만 뜰 수 있다.** 시스템 노드에 강제 배치하면
`Insufficient vpc.amazonaws.com/pod-eni`로 Pending에 걸린다 — 노드 SG로 조용히 폴백하지 않고
명시적으로 실패한다(fail-closed).

> Karpenter NodePool의 `instance-category`에 `t`를 추가하면 이 전제가 조용히 깨진다.
> SGP Pod만 Pending에 걸리고 NodePool 변경과 연결짓기 어렵다.

---

## Prefix Delegation과의 관계

**배타적이지 않다.** 브랜치 ENI 용량은 secondary IP 한도에 **additive**다(c5.4xlarge 기준
secondary IP 234개와 브랜치 ENI 54개가 공존).

문제는 **트렁크 ENI가 인스턴스 ENI 슬롯 하나를 영구 점유**한다는 점이다. Prefix Delegation의
maxPods는 ENI 개수에 비례하는데 계산식이 이를 모르므로 **실제보다 크게 잡힌다.**

> If you've enabled Security Groups per Pod, one of the instance's ENIs is reserved.
> To avoid discrepancies between the `maxPods` value and the node's supported pod density,
> you need to set **`RESERVED_ENIS=1`**.
> — Karpenter 공식 문서

이 값은 VPC CNI가 아니라 **Karpenter 컨트롤러 설정**이다
(`charts/eks-addons/karpenter/*/values.yaml`의 `settings.reservedENIs` → `RESERVED_ENIS` 환경변수).

이 프로젝트에서는 경계가 맞아떨어진다 — `reservedENIs`는 Karpenter가 만드는 노드에만 적용되는데,
"SGP 불가 노드 = 시스템 MNG = Karpenter 관할 밖"이라 낭비가 없다.

### 별개 문제 — SGP Pod가 정원만 차지한다

> Pods that use security groups are **not accounted for in the max-pods formula**... you need to
> consider raising the max-pods value or be ok with running fewer pods than the node can support.
> — EKS Best Practices

브랜치 ENI 용량은 공식 밖에서 늘어나는데 kubelet의 max-pods는 그 Pod를 정원에서 차감한다.
c5.large(ENI 3, IP 10, 브랜치 9) 기준:

```
트렁크 제외 일반 Pod:  2 × (10 − 1) + 2 = 20
SGP Pod:                                    9
실제 총 수용:                              29
```

실제 수용량이 SGP Pod 개수에 따라 달라지는데 `maxPods`는 고정값 하나다.

### 실측 — Prefix Delegation은 Karpenter 노드에 전달되지 않는다

2026-08-12 develop provision에서 측정한 값이다.

| 노드 | 인스턴스 | `vpc.amazonaws.com/pod-eni` | `maxPods` |
|---|---|---|---|
| 시스템 MNG | `t3.medium` | **없음** (t 계열 미지원) | **110** |
| Karpenter | `c5.large` | **9** | **29** |

MNG의 110은 EKS가 노드 그룹 생성 시점에 CNI 설정(프리픽스 모드)을 반영해 계산한 값이다.
반면 **Karpenter는 CNI DaemonSet 설정을 읽지 않고 인스턴스 타입의 ENI/IP 한도만으로
secondary IP 모드 기준 계산을 한다** — `3 × (10−1) + 2 = 29`가 그대로 나온다.

즉 **Prefix Delegation의 pod 밀도 이득이 Karpenter 노드에는 적용되지 않는다.** 이 노드의 실제
IP 용량은 프리픽스 덕에 290에 달하지만 kubelet 상한이 29에서 걸린다.

이 사실은 `RESERVED_ENIS`의 의미도 바꾼다. Karpenter 문서의 전제는 "Karpenter의 계산식과
CNI의 실제 모드가 일치한다"인데 이 구성에서는 어긋나 있다 — `reservedENIs=1`을 적용하면
29 → 20으로 **더 조여진다**. 실제 IP는 남아도는데 상한만 낮추는 셈이다.

그럼에도 설정을 유지하는 이유는 Prefix Delegation을 끄거나 더 작은 인스턴스를 쓰게 되면
트렁크 ENI 손실이 즉시 병목이 되기 때문이다. Karpenter 노드에 pod를 빽빽하게 채워야 하는
상황이 오면 `EC2NodeClass`의 `spec.kubelet.maxPods`를 명시해 두 계산을 일치시킨다.

---

## SG 설계와 소유권

| 리소스 | 위치 | 이유 |
|---|---|---|
| Pod SG (`pod_rds_access`) | `shared/eks-addons/` | 클러스터 공용 신원. GitOps Bridge payload를 조립하는 root가 소유해야 rds root를 역참조하지 않는다 |
| RDS SG + inbound | `shared/rds/` | RDS와 lifecycle이 같다 |

**의존 방향은 `rds` → `eks-addons` 한쪽뿐이다.** Pod SG의 egress를 RDS SG 참조가 아니라 VPC CIDR
대상으로 둬서 순환을 끊었다. 실제 통제는 RDS SG의 inbound에서 일어나므로 egress가 다소 넓어도
목적은 달성된다.

### strict 모드의 일반 원칙 — 목적지 SG가 Pod SG를 받아줘야 한다

Pod SG는 이 Pod가 말을 거는 **모든 목적지**에서 출발지 신원이 된다. egress를 여는 것만으로는
부족하고, **목적지 쪽 SG도 이 SG를 인바운드로 허용**해야 통신이 성립한다.

가장 먼저 걸리는 것이 **DNS**다. CoreDNS는 `role=system` nodeAffinity로 시스템 노드(t3)에
고정돼 있고 SGP Pod는 t 계열에 못 뜨므로, DNS 질의는 반드시 노드를 넘어 VPC를 경유한다.
그런데 노드 SG의 53 인바운드는 업스트림 모듈이 만드는 **self 규칙(출발지 = 노드 SG)뿐**이라
Pod SG를 달고 온 트래픽이 매칭되지 않는다.

| 대상 | 필요한 규칙 | 위치 |
|---|---|---|
| RDS | RDS SG inbound 5432 ← Pod SG | `shared/rds/main.tf` |
| CoreDNS | **노드 SG inbound 53(tcp/udp) ← Pod SG** | `shared/eks-addons/pod-security-groups.tf` |

> **DB 서브넷 그룹은 rds root가 만들지 않는다.** VPC 모듈이 `database_subnets`를 선언하는
> 순간 같은 이름의 서브넷 그룹까지 함께 만들기 때문에, rds root에서 새로 만들면
> `DBSubnetGroupAlreadyExists`로 apply가 실패한다. VPC root의
> `database_subnet_group_name` output을 참조한다 — 이름을 재구성하면 두 root가 각자
> 네이밍 규칙을 알게 되어 한쪽만 바뀌었을 때 조용히 어긋난다.

> SGP를 쓰지 않는 Pod는 노드 ENI로 나가 self 규칙에 걸리므로 이 문제가 드러나지 않는다.
> 그래서 SGP 도입 시점에 처음 터지고, 증상(이름 해석 실패)만 보면 Pod SG egress 쪽을
> 의심하기 쉽다.

### 통제가 성립하는 지점

```
RDS SG inbound:  5432 ← [Pod SG]     ← 여기 한 줄이 전부
```

- SGP Pod: 브랜치 ENI가 Pod SG를 달고 오므로 매칭 → 통과
- 같은 노드의 다른 Pod: 노드 SG를 달고 오므로 매칭 실패 → 차단

**노드 SG를 inbound에 남겨두면 SGP가 무의미해진다.** SG 규칙은 OR로 평가되므로 한 줄만 남아도
그 노드의 모든 Pod가 통과한다. 기존 인프라에 SGP를 적용할 때 가장 흔한 실수다.

### Pod SG egress가 곧 Pod의 통신 범위

`strict` 모드에서 노드 SG의 `egress_all`은 적용되지 않는다. Pod SG에 없는 목적지는 전부 차단된다.

- **DNS(53 TCP/UDP)를 빠뜨리면 이름 해석부터 실패**해 RDS 주소조차 못 찾는다
- `0.0.0.0/0`을 의도적으로 넣지 않았다 — Pod 단위 인터넷 차단이 실제로 강제되는지 검증하는 것이
  이 구성의 목적 중 하나다
- 컨테이너 이미지 pull은 kubelet이 노드 ENI로 수행하므로 Pod SG와 무관하다

### LBC와의 관계

ALB가 이 Pod를 타깃으로 삼게 되면(`target-type: ip`) ALB SG로부터의 inbound가 필요하고, LBC가
자동으로 넣어준다. 단 **Pod SG에 `kubernetes.io/cluster/<cluster_name>` 태그**가 있어야 LBC가
그 SG를 찾는다. 현재 이 Pod SG는 ALB 타깃이 아니라 태그를 붙이지 않았다.

---

## 매니페스트 연동

`SecurityGroupPolicy`는 K8s 리소스라 devops-manifest(ArgoCD) 소관이고, SG는 AWS 리소스라
Terraform 소관이다. **SG ID를 매니페스트로 전달해야 한다.**

SG ID는 apply 시점에 정해지고 teardown/재provision마다 바뀌므로 하드코딩할 수 없다.
`karpenter_node_iam_role_name`과 동일한 경로를 쓴다:

```
Terraform (eks-addons/locals.tf)
  → gitops_bridge_registry_payload.pod_security_group_metadata
  → Hub의 ArgoCD cluster Secret annotation
  → ApplicationSet 템플릿 → chart values
```

---

## teardown 주의

`terminationGracePeriodSeconds: 0`이면 CNI가 Pod 네트워크를 정리하지 못해 **브랜치 ENI가
회수되지 않는다.** 잔존 ENI는 VPC/서브넷 삭제를 막는다.

```bash
# Pod 삭제 후 잔존 확인 (트렁크도 함께 본다)
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=aws-k8s-branch-eni,aws-k8s-trunk-eni" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Status:Status}'
```

트렁크 ENI는 노드와 함께 사라지는 것이 정상이지만, Karpenter 노드를 강제 terminate하는 경로에서는
잔존할 수 있어(`docs/environment-teardown.md`의 "Karpenter 노드 강제 종료로 인한 VPC CNI ENI 잔존")
브랜치와 함께 확인한다.

`docs/environment-teardown.md`의 "VPC CNI secondary ENI 잔존" 항목과 같은 성격이며, SGP는 그
표면을 Pod 수만큼 넓힌다.

RDS는 `deletion_protection = false`, `skip_final_snapshot = true`로 두어 teardown이 사람 손을
타지 않게 했다.

---

## 검증 계획

구축 순서 자체를 검증에 활용한다 — 별도 실험 없이 관측만으로 대부분이 커버된다.

| 단계 | 상태 | 관측 대상 |
|---|---|---|
| 1 | `ENABLE_POD_ENI`만, IAM 미부착 | 트렁크 ENI 생성 실패 |
| 2 | 클러스터 IAM 부착 | `aws-k8s-trunk-eni` 생성, `pod-eni` allocatable 광고 |
| 3 | SGP 적용, `DISABLE_TCP_EARLY_DEMUX` 없이 | **probe 전멸** (strict 고유) |
| 4 | demux 설정 추가 | probe 정상화 |
| 5 | DNS egress 없이 | 이름 해석 실패 |
| 6 | DNS egress 추가 | **본래 목적 검증** — 라벨 있는 Pod만 RDS 접속 성공 |
| 7 | 라벨 없는 Pod, **같은 노드**에서 접속 시도 | 차단 확인 (SGP의 존재 이유) |
| 8 | `reservedENIs: "1"` 적용 | max-pods 변화 |
| 9 | 브랜치 ENI 한도 초과 / t3 노드 배치 시도 | 세 가지 `Insufficient pod-eni` 원인 구분 |
| 10 | Pod SG에 인터넷 egress 없음 | **strict만 가능한 egress 통제 시연** |
| 11 | teardown | 브랜치 ENI·트렁크 ENI 회수 확인 |

주요 확인 명령:

```bash
# 브랜치 ENI 한도 광고 (c5.large면 9)
kubectl get node <karpenter-node> \
  -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/pod-eni}'

# reservedENIs 배선 확인 — 값이 안 변하면 매니페스트 쪽 배선 누락으로 확정
kubectl get node <karpenter-node> -o jsonpath='{.status.allocatable.pods}'
```

### `Insufficient vpc.amazonaws.com/pod-eni`는 원인이 셋이다

`allocatable` 유무만으로는 2가지밖에 못 가른다. 트렁크 ENI 부착 실패(IAM 미부착, 서브넷 IP
고갈, ENI 한도)도 t 계열과 **똑같이 allocatable이 없는 상태**로 보인다.

| 원인 | 판별 |
|---|---|
| 브랜치 ENI 한도 소진 | `allocatable`이 있고 사용량이 그 값과 같음 |
| t 계열 인스턴스 | `allocatable` 없음 + 노드 라벨 `vpc.amazonaws.com/has-trunk-attached` 없음 |
| 트렁크 ENI 부착 실패 | `allocatable` 없음 + `kubectl describe node <node> \| grep -A5 vpc-resource-controller` 이벤트 |

네 번째로, **stale SG ID**는 이 에러가 아니라 VPC Resource Controller 이벤트로만 나타난다.
Pod SG ID는 재provision마다 바뀌는데 Hub 재apply를 빠뜨리면 `SecurityGroupPolicy`가 존재하지
않는 SG를 들고 있게 된다.

### 검증 계획의 한계 (알려진 갭)

- **3·4단계(probe 전멸/정상화)는 현재 테스트 워크로드로 관측할 수 없다.** 요청서의 테스트 Pod가
  `sleep infinity` 컨테이너에 probe가 없기 때문이다. 관측하려면 probe가 붙은 컨테이너가 필요하다.
- 검증용 Pod는 ownerReference가 없는 bare Pod라 **Karpenter consolidation을 차단**한다. 검증이
  끝나면 반드시 제거해야 노드가 정리된다.
- `psql` 접속 시 `sslmode`를 명시하지 않으면 libpq 기본값(`prefer`)으로 붙는다. RDS PostgreSQL
  15 이상은 `rds.force_ssl` 기본값이 `1`이라, SSL 없이 붙으면 `FATAL: no pg_hba.conf entry ...
  SSL off`가 난다 — SG 차단(타임아웃)과 증상이 달라 구분에는 오히려 도움이 되지만, 모르면
  SGP 문제로 오인한다.

---

## 미확인 항목

- 하나의 Pod에 여러 `SecurityGroupPolicy`가 매칭될 때의 동작 (현재 SGP는 하나뿐이라 무관).
- kubelet probe가 Pod SG의 인바운드 평가를 받는지. AWS 문서는 EC2 SGP에서 probe용 ingress를
  요구하지 않고(Fargate SGP 문서는 최소 규칙을 명시하는 것과 대조), `DISABLE_TCP_EARLY_DEMUX`가
  커널 레벨 수정인 점으로 보아 host veth 경로로 처리되어 SG 평가를 받지 않는 것으로 **추론**되나
  문서로 확인하지 않았다.
- EKS가 MNG 생성 시 자동 계산하는 maxPods가 `ENABLE_POD_ENI`를 반영하는지
  (시스템 MNG가 t 계열이라 실질 영향 없음).
- Karpenter NodePool이 허용하는 sub-large 타입(`c6g.medium` 등)의 트렁킹 호환 여부.
  Karpenter v1이 `vpc.amazonaws.com/pod-eni`를 인스턴스 타입 용량으로 모델링하므로 SGP Pod에는
  트렁킹 가능 타입만 고르는 것으로 보이나, 확인하지 않았다. 다만 NodePool이 트렁킹 가능 타입을
  하나도 못 고르는 구성이 되면 SGP Pod가 Pending에 걸린다는 결론은 동일하다.
