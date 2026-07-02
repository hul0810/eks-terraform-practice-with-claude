# modules/eks 설계 원칙

## 모듈 버전 고정 정책

현재 고정된 `terraform-aws-modules/eks/aws` 버전 자체는 `README.md`(terraform-docs 자동 생성)의 `Modules` 섹션에서 확인한다 — `main.tf`의 `version` 제약에서 직접 추출되므로 여기 별도로 적으면 drift만 생긴다.

`~> X.Y.Z`(패치만 허용)로 고정하는 이유는 `@docs/terraform-principles.md`(버전 관리)에 공통 기술되어 있다. 이 모듈은 마이너 업그레이드(예: v21.22.0 → v21.23.0)를 자동 추적하지 않고 CHANGELOG 확인 후 의도적으로 수동 변경한다 — `terraform-aws-modules/eks/aws`는 마이너 버전에서도 `cluster_name`→`name` 같은 인터페이스 변경이 있었던 전례(아래 "v20 → v21 주요 파라미터 변경 사항" 참조)가 있어 자동 업그레이드가 위험하기 때문이다.

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
| `clusterSecurityGroupId` (eks-cluster-sg-*) | EKS 자동 생성 | EKS owned ENI + 노드 EC2 | 노드 ↔ 컨트롤 플레인 기본 통신 채널 (self-reference ALL) |
| `cluster_sg` (`create_security_group = true`) | 모듈 생성 | EKS owned ENI | 외부 접근 제어 앵커 — Bastion/VPN SG 화이트리스트 추가 시 이 SG에 인바운드 규칙을 붙인다. 현재 규칙 없음 |
| `node_sg` | 모듈 생성 | 노드 EC2 | 노드 레벨 트래픽 제어 |

### node_sg에 추가된 커스텀 규칙 (`node_security_group_additional_rules`)

| 키 | 방향 | 포트 | 목적 |
|----|------|------|------|
| `ingress_self_all` | 노드 → 노드 | ALL | ICMP·UDP 등 모듈 기본값(1025-65535/tcp)이 커버하지 못하는 비-TCP 프로토콜 허용 |

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

### capacity_type ON_DEMAND 하드코딩 이유

시스템 노드 그룹에는 다음 컴포넌트가 실행된다:
- Karpenter (클러스터 오토스케일러) — Pod로 배포됨
- CoreDNS (클러스터 DNS)
- AWS Load Balancer Controller
- kube-proxy

Karpenter는 Pod이므로 이 노드가 Spot 중단되면 클러스터 자가 회복 능력 자체가 상실된다.

- Karpenter 종료 → 신규 노드 프로비저닝 불가 → Pending Pod 무한 대기
- CoreDNS 종료 → 클러스터 내 DNS 해석 실패 → 서비스 간 통신 장애

**비용 절감용 Spot은 Karpenter NodePool(앱 워크로드 레이어)에서 적용한다.** Karpenter는 Spot 중단을 감지하고 graceful drain + 신규 노드 프로비저닝을 자동으로 처리하므로, 앱 워크로드 레이어에서는 Spot 사용이 안전하다.

이 구분이 EKS + Karpenter 아키텍처의 올바른 계층적 비용 최적화 전략이며, `capacity_type`은 변수화하지 않고 하드코딩으로 강제한다.

### CriticalAddonsOnly Taint

일반 워크로드 Pod가 시스템 노드에 스케줄되지 않도록 격리한다.
시스템 노드는 사양이 작으므로(t3.medium) 일반 워크로드와 리소스를 공유하면 시스템 컴포넌트가 OOM으로 종료될 위험이 있다.
시스템 애드온은 `tolerations: [{key: "CriticalAddonsOnly", value: "true", effect: "NoSchedule"}]`을 명시하여 허용한다.

### 실행 환경 구조: eks/ 한 폴더로 관리

EKS 클러스터, 시스템 노드 그룹, bootstrap addon 7종을
단일 실행 환경(`environments/.../eks/`)에서 `module "eks"` 하나로 관리한다.

이유:
- 클러스터, 노드 그룹, bootstrap addon은 하나의 구축 시퀀스로 묶여 lifecycle이 동일하다.
- 별도 폴더로 분리하면 apply 순서 강제 및 운영 혼동이 발생한다.
- `before_compute` 파라미터가 배포 순서를 모듈 내부에서 처리하므로 외부 분리가 불필요하다.

Karpenter, LBC 등 애플리케이션 레벨 addon은 클러스터 구축 후 독립 운영하므로
별도 실행 환경으로 분리한다.
