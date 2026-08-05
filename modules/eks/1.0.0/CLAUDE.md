# modules/eks 설계 원칙

## 모듈 버전 고정 정책

현재 고정된 `terraform-aws-modules/eks/aws` 버전 자체는 `README.md`(terraform-docs 자동 생성)의 `Modules` 섹션에서 확인한다 — `main.tf`의 `version` 제약에서 직접 추출되므로 여기 별도로 적으면 drift만 생긴다.

`~> X.Y.Z`(패치만 허용)로 고정하는 이유는 `docs/terraform-principles.md`(버전 관리)에 공통 기술되어 있다. 이 모듈은 마이너 업그레이드(예: v21.22.0 → v21.23.0)를 자동 추적하지 않고 CHANGELOG 확인 후 의도적으로 수동 변경한다 — `terraform-aws-modules/eks/aws`는 마이너 버전에서도 `cluster_name`→`name` 같은 인터페이스 변경이 있었던 전례(아래 "v20 → v21 주요 파라미터 변경 사항" 참조)가 있어 자동 업그레이드가 위험하기 때문이다.

---

## Add-on 버전 관리

전체 정책: `docs/addon-strategy.md` 참조 (관리형 우선 원칙, 분류표, Pod Identity 패턴).

### 이 모듈이 관리하는 범위

**Bootstrap 애드온 6종** 이 모듈에서 관리한다. 나머지 애드온(LBC, ExternalDNS, Karpenter 등)은 `modules/eks-addons`에서 관리한다.

- 분리 이유: bootstrap 애드온은 노드 조인 및 IAM 연동의 전제 조건이라 클러스터 lifecycle에 묶여야 한다.
  나머지는 클러스터 구축 후 독립적으로 설치·운영한다.

Bootstrap 7종은 `before_compute` 파라미터로 배포 순서를 제어한다. 모두 `module "eks"` 내 `addons` 블록에 선언하며, 별도 서브모듈 호출이나 외부 `aws_eks_addon` 리소스가 불필요하다:

| before_compute | 포함 애드온 | 이유 |
|----------------|-------------|------|
| `true` (노드 그룹 이전) | eks-pod-identity-agent, vpc-cni | aws-node Pod Identity 크레덴셜 획득 전제 조건; 노드 조인 전 CNI ACTIVE 보장 |
| `false` (기본값, 노드 그룹 이후) | kube-proxy, coredns, aws-ebs-csi-driver, cert-manager | EKS가 즉시 ACTIVE 표시하거나(kube-proxy, ebs-csi), 노드 없이는 ACTIVE 불가(coredns, cert-manager) |

**coredns를 before_compute = false로 처리하는 이유:**
coredns는 Kubernetes Deployment이므로 실행 노드가 없으면 Pod가 스케줄되지 않아 ACTIVE 상태가 되지 않는다.
`before_compute = false`(기본값)로 선언하면 모듈이 `depends_on = [module.eks_managed_node_group]`을 내부적으로 자동 추가하여 노드 그룹 완료 후 coredns를 설치한다. 이전 구조(Phase 3: 외부 `aws_eks_addon "coredns"`)와 동일한 안전성을 단일 모듈 호출로 달성한다.

### IAM 전략 — Pod Identity vs IRSA

`enable_irsa = true`로 OIDC Provider를 활성화한다.

| 설치 방식 | IAM 전략 | 비고 |
|-----------|----------|------|
| `aws_eks_addon` (이 모듈의 EBS CSI, VPC CNI) | **Pod Identity** | `addons` 블록 내 `pod_identity_association` 인라인 전달 |
| blueprints Helm (modules/eks-addons) | **IRSA** | blueprints 모듈이 IRSA만 지원하기 때문 |

OIDC Provider(`oidc_provider_arn` output)는 modules/eks-addons의 blueprints가 사용한다.

### Pod Identity IAM Role 네이밍 규칙

**네이밍 패턴**: `{cluster_name}-{addon}-pod-id`

| 리소스 | 이름 | 예시 |
|--------|------|------|
| VPC CNI Pod Identity Role | `{cluster_name}-vpc-cni-pod-id` | `eks-practice-dev-vpc-cni-pod-id` |
| EBS CSI Driver Pod Identity Role | `{cluster_name}-ebs-csi-driver-pod-id` | `eks-practice-dev-ebs-csi-driver-pod-id` |

`-pod-id` 접미사로 IAM 방식(Pod Identity)을 식별한다 — `modules/eks-addons`의 `-irsa` 접미사(IRSA 식별)와 대칭되는 규칙이다.
IAM Role `name`은 변경 시 리소스 재생성(ForceNew)을 유발하므로, 이 패턴이 확정된 이후에는 임의로 바꾸지 않는다.

**`create_before_destroy` 필수**: `aws_iam_role.vpc_cni`/`ebs_csi`와 그 `aws_iam_role_policy_attachment`는 모두
`lifecycle { create_before_destroy = true }`를 갖는다. `name` 변경(ForceNew)이 기본 destroy→create 순서로 실행되면,
구 Role이 삭제된 시점과 `addons` 블록의 `pod_identity_association.role_arn`이 신규 ARN으로 갱신되는 시점 사이에
association이 이미 삭제된 Role을 가리키는 구간이 생겨 aws-node/ebs-csi-controller의 자격 증명 갱신이 실패할 수 있다.
CBD로 신규 Role을 먼저 만들면 이 구간이 사라진다. Role의 `name`을 다시 바꿀 일이 있다면 이 lifecycle 블록을 유지한 채 진행한다.

### 버전 관리

모든 애드온 버전은 모듈 내부에 하드코딩하지 않는다.
`environments/.../eks/locals.tf`의 `eks.addon_versions`에서 지정한다.

```hcl
# environments/.../eks/locals.tf
addon_versions = {
  vpc_cni                  = "v1.20.5-eksbuild.1"
  kube_proxy               = "v1.33.10-eksbuild.2"
  coredns                  = "v1.12.4-eksbuild.10"
  eks_pod_identity_agent   = "v1.3.10-eksbuild.3"
  ebs_csi_driver           = "v1.60.1-eksbuild.1"
  cert_manager             = "v1.20.2-eksbuild.3"
}
```

버전 조회:
```bash
aws eks describe-addon-versions --kubernetes-version 1.33 --addon-name <name> \
  --region ap-northeast-2 \
  --query 'addons[].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion' \
  --output text
```

### 업그레이드 절차

1. 신규 버전 조회
   ```bash
   aws eks describe-addon-versions \
     --kubernetes-version <k8s-ver> \
     --addon-name <addon-name> \
     --region ap-northeast-2
   ```
2. `defaultVersion: true` 버전 확인 (또는 패치 릴리스 CHANGELOG 검토)
3. `main.tf`의 `addon_version` 값 수동 변경
4. `terraform plan` 검토 후 `terraform apply`

---

## VPC CNI Prefix Delegation — 노드당 pod 상한

### 채택 배경

노드당 pod 상한은 인스턴스 성능이 아니라 **VPC CNI가 pod 1개당 ENI의 보조 IP 1개를 소모하는 기본 동작**에서 온다.

```
세컨더리 IP 모드: ENI 개수 × (ENI당 IPv4 주소 개수 − 1) + 2
Prefix 모드     : ENI 개수 × (ENI당 IPv4 주소 개수 − 1) × 16 + 2
```

`− 1`은 각 ENI의 primary IP(파드에 배정 불가), `+ 2`는 hostNetwork 파드(`kube-proxy`, `aws-node`) 몫이다.
t3.medium(ENI 3 × IP 6)은 세컨더리 모드에서 **17**이라, CPU·메모리가 남는데도 `Too many pods`로 스케줄이 막힌다.
Prefix Delegation은 **추가 비용 없이** 이 상한만 걷어낸다 — 인스턴스 타입·노드 수를 바꾸지 않으므로 비용 정책과 충돌하지 않는다.

### 설정 방법

`vpc_cni_configuration_values`로 전달한다(환경 `eks/locals.tf`).

```hcl
vpc_cni_configuration_values = jsonencode({
  env = { ENABLE_PREFIX_DELEGATION = "true" }
})
```

**`WARM_PREFIX_TARGET`은 선언하지 않는다.** 애드온 기본값이 이미 AWS 권장값(1)이라, 같은 값을 고정하면 향후 권장값이 바뀌어도 따라가지 못한다.
`env` 하위 값은 스키마상 전부 문자열이다(`aws eks describe-addon-configuration --addon-name vpc-cni`로 확인).

### maxPods 반영 시점 — 애드온 설정만 바꾸면 소급 적용되지 않는다

**EKS는 노드 그룹을 생성·업데이트하는 시점에 maxPods를 계산해 내부 launch template의 nodeadm `NodeConfig`에 굽는다.**

```yaml
# EKS가 생성한 내부 LT의 user data
spec:
  kubelet:
    config:
      maxPods: 17     # ← 노드 그룹 생성 시점에 고정
```

| 상황 | 결과 |
|------|------|
| fresh provision | **자동 반영** — `before_compute = true`가 vpc-cni를 노드 그룹보다 먼저 ACTIVE로 만들어 EKS가 프리픽스 모드 기준으로 계산한다 |
| 기존 클러스터에 애드온 설정만 변경 | **반영 안 됨** — CNI는 즉시 프리픽스를 할당하지만 kubelet 상한은 옛 값이 남는다 |

`vpc-cni`의 `before_compute = true`는 원래 "노드 조인 전 CNI ACTIVE 보장"이 목적이지만 **maxPods 계산 순서까지 보장하는 두 번째 역할**을 갖는다 — false로 바꾸면 fresh provision에서도 프리픽스 모드가 maxPods에 반영되지 않는다.

### 기존 클러스터에 소급 적용

노드 교체가 필요하다(클러스터·노드 그룹 재생성은 불필요). **트리거는 custom launch template의 버전 변경**이다.

```bash
# 동일 release version + --force → no-op. LT가 재생성되지 않아 maxPods가 그대로다.
aws eks update-nodegroup-version --cluster-name <cl> --nodegroup-name <ng> --force

# custom LT 버전을 올린 뒤 지정해야 실제 롤링 교체가 일어난다.
aws eks update-nodegroup-version --cluster-name <cl> --nodegroup-name <ng> \
  --launch-template id=<lt-id>,version=<new> --force
```

관리형 노드 그룹은 default 전략에서 **새 노드를 먼저 띄우고 기존 노드를 나중에 비운다**. 노드 2대 기준 실측으로 신규 노드 Ready까지 약 1분, 구 노드 cordon까지 약 5분, 전체 완료 약 23분이 걸렸고 그 사이 ASG가 최대 8대까지 증설된 뒤 원복됐다.

### 적용 상한과 판단 기준

| 대상 | 값 |
|------|-----|
| MNG (EKS 자동 계산) | 30 vCPU 미만 **110**, 이상 **250** — 이론값과 무관하게 이 상한이 적용된다 |
| Karpenter 노드 | Karpenter가 자체 계산한다. **필요해지면 EC2NodeClass `spec.kubelet.maxPods`에 명시하기로 한다**(Karpenter v1부터 NodePool이 아닌 EC2NodeClass 소관, `karpenter-resources`는 devops-manifest 소관) |

**상향 여부는 실측으로 판단한다** — `Too many pods`로 스케줄이 막힌 시점에 **그 노드의 CPU·메모리가 놀고 있을 때만** 올린다. 자원도 함께 포화 상태라면 상한이 아니라 인스턴스 타입·노드 수 문제다.

### 서브넷 요구사항

`/28` 프리픽스는 **연속된 16개 IP 블록**이어야 하므로 단편화된 서브넷에서는 할당이 실패한다(`InsufficientCidrBlocks`). 이 프로젝트의 프라이빗 서브넷은 `/19`(= `/28` 블록 512개)라 여유가 크지만, 더 작은 CIDR로 신규 환경을 만들 때는 [Subnet CIDR 예약](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-cidr-reservation.html)을 검토한다.

---

## gp3 기본 StorageClass 옵션

### 변수: `enable_default_storage_class` (기본값 `false`)

EKS 기본 제공 StorageClass는 gp2(레거시 in-tree provisioner `kubernetes.io/aws-ebs`)이며 default 지정도 없다 — 차트가 `storageClassName`을 생략하면 PVC가 전부 Pending된다. gp3는 gp2보다 저렴하고 성능도 높으며 이 모듈이 addon으로 관리하는 EBS CSI Driver(`ebs.csi.aws.com`)를 사용한다. EBS CSI addon과 동일한 부트스트랩 레이어에 속하므로 `modules/eks-addons`가 아닌 이 모듈이 `kubernetes_storage_class_v1.gp3`(`storage-class.tf`)를 소유한다.

`count = var.enable_default_storage_class ? 1 : 0`으로 토글한다 — `for_each`가 아닌 `count`를 쓰는 이유: on/off 두 상태만 존재하는 단일 리소스라 stable key로 관리할 다중 인스턴스가 없다(`docs/terraform-principles.md`의 `count` 금지 규칙은 인덱스 이동으로 인한 재생성 리스크가 있는 다중 리소스 관리에 적용되는 것이지, 단일 리소스의 on/off 토글에는 해당하지 않는다).

### 이 옵션을 켜는 root의 요구사항

`enable_default_storage_class = true`로 설정하는 root는 **kubernetes provider를 반드시 구성해야 한다**(exec 인증, `aws eks get-token`). `false`(기본값)인 root는 kubernetes provider와 전혀 상호작용하지 않으므로 provider 미구성 상태에서도 안전하다 — dev/prod처럼 클러스터를 아직 생성하지 않은 root가 이 모듈을 호출해도 planning이 깨지지 않는다.

| 환경 | 값 | 비고 |
|------|-----|------|
| monitoring | `true` | 기존 root에 직접 선언되어 있던 리소스를 `moved` 블록으로 이전(재생성 없음) |
| develop | `true` | 신규 kubernetes provider 구성 필요 |
| production | `true` | 신규 kubernetes provider 구성 필요 |

---

## KMS 암호화 전략

### 설계 결정: AWS 관리형 키 사용 (CMK 비활성화)

`terraform-aws-modules/eks/aws` v21.x는 `create_kms_key = true`가 기본값이므로,
명시적으로 비활성화하지 않으면 EKS secrets 봉투암호화용 CMK가 자동 생성된다.

이 모듈은 아래 파라미터로 CMK 생성을 억제하고 AWS 관리형 etcd 암호화를 사용한다:

```hcl
create_kms_key           = false
attach_encryption_policy = false
encryption_config        = null
```

| 파라미터 | 역할 |
|----------|------|
| `create_kms_key = false` | CMK(`aws_kms_key`, `aws_kms_alias`) 리소스 생성 억제 |
| `attach_encryption_policy = false` | 클러스터 IAM Role에 `kms:Decrypt` 정책 첨부 억제 (CMK 미사용 시 불필요) |
| `encryption_config = null` | 봉투암호화 블록 생성 자체를 억제 (아래 주의사항 참고) |

> **주의**: 업스트림 변수 기본값이 `{}`(빈 오브젝트)이며, 모듈 내부 평가 로직은
> `enable_encryption_config = var.encryption_config != null`이다.
> `{}`는 null이 아니므로 기본값 그대로 두면 `encryption_config` 블록이 생성되고,
> `provider_key_arn`이 null인 상태로 AWS API를 호출하여 **apply가 실패**한다.
> 반드시 `encryption_config = null`을 명시해야 블록 생성이 억제된다.

### CMK를 사용하지 않는 근거

- **비용**: CMK는 $1/월 + KMS API 호출 비용. 이 프로젝트 규모에서 정당화하기 어렵다.
- **운영 부담**: CMK는 키 순환, 키 정책 관리, 삭제 대기 기간(최소 7일) 등 추가 운영이 필요하다.
- **보안 충분성**: AWS 관리형 키도 AES-256 봉투암호화를 제공하며, etcd 저장 데이터를 보호한다.

### CMK가 필요한 경우

아래 요건이 생기면 `create_kms_key = true`로 전환하거나 외부 CMK ARN을 `encryption_config.provider_key_arn`에 지정한다:

- 규정 준수(PCI-DSS, HIPAA 등)로 고객 관리 키가 의무화된 경우
- 키 접근 감사 로그(CloudTrail KMS API)가 필요한 경우
- 키 공유 범위를 교차 계정으로 제어해야 하는 경우

---

## v20 → v21 주요 파라미터 변경 사항

MCP(GitHub raw) 확인 결과 기준:

| 항목 | v20 | v21 |
|------|-----|-----|
| 클러스터 이름 | `cluster_name` | `name` |
| Kubernetes 버전 | `cluster_version` | `kubernetes_version` |
| 노드 그룹 정의 | `eks_managed_node_groups` | `eks_managed_node_groups` (동일, 내부 스키마 변경) |
| taint 스키마 | `list(object(...))` | `map(object({ key, value, effect }))` |
| 기본 authentication_mode | 미지원 | `"API_AND_CONFIG_MAP"` (기본값) |

> **중요**: v21에서 `cluster_name` → `name`, `cluster_version` → `kubernetes_version` 으로 변경되었다.
> 이 모듈의 `variables.tf`는 외부 인터페이스 일관성을 위해 `cluster_name`, `kubernetes_version`을 유지하고,
> `main.tf` 내부에서 `name = var.cluster_name`으로 매핑한다.

---

## create_before_destroy 내부 하드코딩 여부

`terraform-aws-modules/eks` v21.x의 서브모듈 `modules/eks-managed-node-group/main.tf`에
`create_before_destroy = true`가 이미 하드코딩되어 있다.

```hcl
# modules/eks-managed-node-group/main.tf (모듈 내부)
lifecycle {
  create_before_destroy = true
  ignore_changes = [
    scaling_config[0].desired_size,
  ]
}
```

따라서 `eks_managed_node_groups` 블록 내에서 `lifecycle` 블록을 별도로 선언하면 오류가 발생한다.

---

## Security Group Rule 관리 패턴

### 원칙: for_each 기반 stable key 관리

SG rule 관리의 핵심은 **리소스 주소의 안정성**이다. 잘못된 패턴은 rule 추가/삭제 시
의도치 않은 재생성(일시 차단)을 유발한다:

| 패턴 | 문제 |
|------|------|
| `aws_security_group` 인라인 블록 | rule 변경 시 SG 전체 재생성 → 모든 rule 일시 삭제 |
| `count` 기반 리소스 | 중간 삽입/삭제 시 인덱스 이동 → 후속 rule 전부 재생성 |
| `for_each` 기반 리소스 | `["key"]` 주소로 관리 — 다른 rule에 영향 없이 추가/삭제 가능 |

### v21.x 공식 모듈의 구현 방식

`terraform-aws-modules/eks/aws` v21.x는 단일 `for_each`로 모든 node SG rule을 통합 관리한다:

```hcl
# terraform-aws-eks v21.x node_groups.tf (소스 확인 완료)
resource "aws_security_group_rule" "node" {
  for_each = { for k, v in merge(
    local.node_security_group_rules,
    local.node_security_group_recommended_rules,
    var.node_security_group_additional_rules,   # ← 여기 병합
  ) : k => v if local.create_node_sg }
}
```

→ `node_security_group_additional_rules`로 전달한 규칙은 동일한 `for_each`에 병합되어
`aws_security_group_rule.node["ingress_self_all"]`처럼 stable key로 관리된다.
`for_each` 기반이므로 원칙의 목적이 모듈 내부에서 달성된다.

### 적용 규칙

- **node SG 추가 규칙**: `node_security_group_additional_rules` 파라미터로 전달
  (외부에서 `module.eks.node_security_group_id`를 참조해 별도 리소스 주입 금지 — 모듈 소유권 침해)
- **공식 모듈이 `count`-based이거나 파라미터가 없는 경우**: 외부에 `for_each`-based 별도 리소스 선언
  (현재 v21.x에는 해당 없음)
- **어떤 경우에도 금지**: 인라인 블록 및 `count`-based 패턴

---

## Security Group 구조 및 역할

### 3계층 구조

| SG | 생성 주체 | 부착 대상 | 역할 |
|----|-----------|-----------|------|
| `clusterSecurityGroupId` (eks-cluster-sg-*) | EKS 자동 생성 | EKS owned ENI **만** | 컨트롤 플레인 ENI의 egress(all → 0.0.0.0/0) 담당. `attach_cluster_primary_security_group` 기본값이 `false`라 노드에는 부착되지 않으므로, 이 SG의 self-reference ALL 규칙은 실제로 매칭되는 트래픽이 없다 |
| `cluster_sg` (`create_security_group = true`) | 모듈 생성 | EKS owned ENI (additional) | 노드 → API 서버 443 인그레스를 허용하고, 동시에 node_sg 인그레스 규칙들의 `source_cluster_security_group` 앵커가 된다. Bastion/VPN 화이트리스트도 이 SG에 붙인다 |
| `node_sg` | 모듈 생성 | 노드 EC2 (관리형 노드 그룹·Karpenter 노드 전부) | 노드 레벨 트래픽 제어 |

### 컨트롤 플레인 ↔ 데이터 플레인 경로

방향별로 어느 SG가 관여하는지가 다르다. primary SG가 노드에 붙지 않으므로 **양방향 모두
`cluster_sg` ↔ `node_sg` 상호 참조로만 성립한다** — primary SG에 규칙을 추가해도 노드에는
적용되지 않는다.

| 방향 | egress | ingress |
|---|---|---|
| API 서버 → 노드 (kubelet 10250, webhook 등) | primary SG의 all (SG는 합집합 평가되므로 `cluster_sg`에 egress 규칙이 없어도 동작) | `node_sg`의 포트별 규칙, source = `cluster_sg` |
| 노드 → API 서버 | `node_sg`의 all | `cluster_sg`의 443 |

**엔드포인트 모드에 따른 차이**: 이 모듈은 `endpoint_private_access = true`를 고정하므로
VPC 내부에서 나가는 API 요청은 항상 private endpoint(cross-account ENI)를 거치고, 위
"노드 → API 서버" 행이 유효하다. `endpoint_private_access = false`로 바꾸면 노드가 NAT
Gateway를 통해 public endpoint로 붙게 되어 `cluster_sg`의 443 규칙이 무의미해지고 대신
`endpoint_public_access_cidrs`에 NAT Gateway EIP를 넣어야 노드가 조인한다
([AWS 문서](https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html) —
조합별 동작표). 반면 cross-account ENI 자체는 엔드포인트 설정과 무관하게 항상 생성되므로
**"API 서버 → 노드" 행은 어떤 모드에서도 그대로 필요하다** — 아래 10260 같은 webhook 포트
문제는 엔드포인트 모드를 바꿔도 해소되지 않는다.

### node_sg에 추가된 커스텀 규칙 (`node_security_group_additional_rules`)

| 키 | 방향 | 포트 | 목적 | 정의 위치 |
|----|------|------|------|-----------|
| `ingress_self_all` | 노드 → 노드 | ALL | ICMP·UDP 등 모듈 기본값(1025-65535/tcp)이 커버하지 못하는 비-TCP 프로토콜 허용 | 호출자(root) |
| `ingress_cluster_10260_cert_manager_webhook` | 컨트롤 플레인 → 노드 | 10260/tcp | cert-manager admission webhook 호출 경로 | **이 모듈 기본값** |

`ingress_cluster_10260_cert_manager_webhook`은 `main.tf`에서 `merge()`로 주입하는 모듈
기본값이다. cert-manager를 이 모듈이 bootstrap 애드온으로 설치하는 이상 모든 환경에서
항상 필요하므로 환경별 주입 대상이 아니다. 호출자가 `node_security_group_additional_rules`에
같은 키를 넣으면 덮어쓴다.

**왜 443이 아니라 10260인가**: cert-manager webhook은 `--secure-port=10260`으로 뜨고
Service가 `443 → targetPort "https"(=10260)`로 매핑한다. `ValidatingWebhookConfiguration`에는
`port: 443`이라고 적혀 있지만 **EKS 컨트롤 플레인은 ClusterIP를 라우팅할 수 없다** — AWS
관리 VPC에서 돌고 고객 VPC에는 크로스 계정 ENI(`RequesterManaged=true`)만 꽂혀 있어 그
경로에 kube-proxy가 없기 때문이다. 그래서 API 서버는 Service를 Endpoints로 해석해
`<파드IP>:<targetPort>`로 직접 연결하며, SG 평가 대상도 10260이 된다. 업스트림이 만드는
규칙 이름들(`Cluster API to node 4443/tcp webhook` 등)이 이미 같은 사실의 증거다 — 443이
열려 있는데도 컨테이너 포트를 따로 열어둔다.

**왜 업스트림 recommended rules로 커버되지 않는가**: 그 목록은 4443/6443/8443/9443/
10250/10251로 고정돼 있다. cert-manager는 원래 10250(kubelet 포트)을 쓰다가 10260으로
독립했는데, 10250은 kubelet용으로 이미 열려 있어 그동안 **우연히** 동작했다. 포트가
분리되면서 그 우연이 사라졌고 업스트림 목록은 아직 10260을 포함하지 않는다.

**영향 범위**: `cert-manager-webhook`은 `failurePolicy: Fail` + `resources: '*/*'`이다.
즉 webhook 도달 불가는 특정 addon 하나의 문제가 아니라 **cert-manager API 그룹 리소스를
아무것도 만들 수 없는 상태**이며, cert-manager에 의존하는 모든 향후 컴포넌트가 동일하게
막힌다.

> cert-manager를 설치해두기만 하고 `Certificate`/`Issuer`를 한 번도 만들지 않으면 webhook이
> 호출될 일이 없어 이 규칙의 부재가 드러나지 않는다. LBC와 ESO는 자체 인증서 생성기를 써서
> cert-manager 경로를 타지 않으므로, OTel Operator처럼 cert-manager로 자기 webhook 인증서를
> 발급받는 컴포넌트를 추가하는 시점에 처음 문제가 된다.

### node_sg Karpenter 탐색 태그 (`node_security_group_tags`)

Karpenter EC2NodeClass의 `securityGroupSelectorTerms`는 `karpenter.sh/discovery = {cluster_name}` 태그로 node SG를 자동 탐색한다.
`node_security_group_tags` 변수로 이 태그를 주입한다.

```hcl
# environments/.../eks/main.tf 호출 예시
node_security_group_tags = {
  "karpenter.sh/discovery" = local.cluster_name
}
```

`node_security_group_tags`에 넣는 이유: VPC `private_subnet_tags`의 `karpenter.sh/discovery`와 동일한 값을 node SG에도 부여해야 Karpenter가 서브넷과 SG를 동시에 탐색할 수 있다. 두 값이 불일치하면 EC2NodeClass가 SG를 0개 탐색해 노드 프로비저닝이 실패한다.

### 모듈이 node_security_group_recommended_rules로 이미 생성하는 규칙 (중복 선언 금지)

| 모듈 내부 키 | 방향 | 포트 | 목적 |
|---|---|---|---|
| `ingress_cluster_443` | 컨트롤 플레인 → 노드 | 443/tcp | Cluster API → node groups |
| `ingress_cluster_kubelet` | 컨트롤 플레인 → 노드 | 10250/tcp | Cluster API → kubelets |
| `ingress_self_coredns_tcp/udp` | 노드 → 노드 | 53 | CoreDNS |
| `ingress_nodes_ephemeral` | 노드 → 노드 | 1025-65535/tcp | 노드 간 일반 통신 |
| `ingress_cluster_8443_webhook` | 컨트롤 플레인 → 노드 | 8443/tcp | Karpenter Admission Webhook |
| `ingress_cluster_9443_webhook` | 컨트롤 플레인 → 노드 | 9443/tcp | ALB Controller, NGINX |
| `egress_all` | 노드 → 외부 | ALL | ECR Pull, AWS API, 패키지 다운로드 |

위 규칙과 동일한 리소스를 커스텀 모듈에 추가하면 `InvalidPermission.Duplicate` 오류 발생.

---

## 시스템 노드 그룹 설계 근거

### Karpenter 부트스트랩 문제

Karpenter는 EKS 클러스터에서 노드를 자동으로 프로비저닝하는 오토스케일러다.
하지만 Karpenter 자체가 실행될 노드가 없으면 기동할 수 없다는 닭-달걀 문제가 있다.
이를 해결하기 위해 Karpenter가 배포되기 전부터 존재하는 별도의 Managed Node Group(시스템 노드 그룹)을 구성한다.

### capacity_type — 환경별 선택 가능 (기본값 ON_DEMAND)

시스템 노드 그룹에는 다음 컴포넌트가 실행된다:
- Karpenter (클러스터 오토스케일러) — Pod로 배포됨
- CoreDNS (클러스터 DNS)
- AWS Load Balancer Controller
- kube-proxy

Karpenter는 Pod이므로 이 노드가 Spot 중단되면 클러스터 자가 회복 능력 자체가 상실된다.

- Karpenter 종료 → 신규 노드 프로비저닝 불가 → Pending Pod 무한 대기
- CoreDNS 종료 → 클러스터 내 DNS 해석 실패 → 서비스 간 통신 장애

**비용 절감용 Spot은 원칙적으로 Karpenter NodePool(앱 워크로드 레이어)에서 적용한다.** Karpenter는 Spot 중단을 감지하고 graceful drain + 신규 노드 프로비저닝을 자동으로 처리하므로, 앱 워크로드 레이어에서는 Spot 사용이 안전하다.

`system_node_capacity_type` 변수(기본값 `"ON_DEMAND"`)로 시스템 노드 그룹에도 SPOT을 선택할 수 있다.
단, 위 리스크(Karpenter 자가 회복 불능)는 SPOT을 선택하는 순간 호출자가 그대로 떠안는다 — 모듈은 이를
막지 않는다. 가용성이 중요한 환경(production)은 ON_DEMAND를 유지하고, 실습·비용 절감 목적으로
리스크를 감수할 수 있는 환경(develop, monitoring)만 명시적으로 SPOT을 선택한다(루트 `CLAUDE.md`의
비용 예외 항목 참조).

### CriticalAddonsOnly Taint

일반 워크로드 Pod가 시스템 노드에 스케줄되지 않도록 격리한다.
시스템 노드는 사양이 작으므로(t3.medium) 일반 워크로드와 리소스를 공유하면 시스템 컴포넌트가 OOM으로 종료될 위험이 있다.
시스템 애드온은 `tolerations: [{key: "CriticalAddonsOnly", value: "true", effect: "NoSchedule"}]`을 명시하여 허용한다.

### Cluster Autoscaler 자동탐색 — 별도 설정 불필요 (실측 확인)

이 시스템 노드 그룹은 Terraform이 `min/max/desired_size`를 고정값으로 관리하는 정적
그룹이라, 애드온이 늘어나 pod 슬롯이 부족해져도 자동으로 확장되지 않는다. Karpenter는
이 노드 그룹을 전혀 관리하지 않으므로(자기 NodePool 대상만 관리) 대신 Cluster Autoscaler로
이 노드 그룹만 별도 스코프해 동적 확장을 붙인다 — Karpenter는 ASG를 쓰지 않아 두
오토스케일러가 노드 집합을 두고 충돌할 여지가 구조적으로 없다.

CA의 `--node-group-auto-discovery`가 찾는 태그(`k8s.io/cluster-autoscaler/enabled`,
`k8s.io/cluster-autoscaler/{cluster_name}=owned`)와 확장/축소 쓰기 권한 조건에 쓰이는
`kubernetes.io/cluster/{cluster_name}=owned` 태그 전부, **AWS EKS가 관리형 노드 그룹의
ASG 생성 시점에 자동으로 부여한다** — Terraform에서 별도로 설정할 게 없다(2026-07-25
`aws autoscaling describe-tags`로 실측 확인: 노드 그룹 생성 직후, 이 프로젝트가 태그 관련
코드를 추가하기 전부터 이미 4개 태그가 모두 존재했다). `terraform-aws-modules/eks/aws`의
`eks-managed-node-group` 서브모듈에는 애초에 `autoscaling_group_tags` 같은 옵션 자체가
없다 — `self-managed-node-group` 서브모듈에만 있는 옵션이라 관리형 노드 그룹을 쓰는 이
프로젝트에는 해당하지 않는다(IAM 정책 쪽 상세는 `modules/eks-addons/2.0.0/CLAUDE.md`
cluster-autoscaler 절 참조).

### 실행 환경 구조: eks/ 한 폴더로 관리

EKS 클러스터, 시스템 노드 그룹, bootstrap addon 7종을
단일 실행 환경(`environments/.../eks/`)에서 `module "eks"` 하나로 관리한다.

이유:
- 클러스터, 노드 그룹, bootstrap addon은 하나의 구축 시퀀스로 묶여 lifecycle이 동일하다.
- 별도 폴더로 분리하면 apply 순서 강제 및 운영 혼동이 발생한다.
- `before_compute` 파라미터가 배포 순서를 모듈 내부에서 처리하므로 외부 분리가 불필요하다.

Karpenter, LBC 등 애플리케이션 레벨 addon은 클러스터 구축 후 독립 운영하므로
별도 실행 환경으로 분리한다.
