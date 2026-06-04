# modules/eks 설계 원칙

## 사용 모듈 버전

`terraform-aws-modules/eks/aws` v21.22.0 (2026-05-28 기준 최신)

---

## Add-on 버전 관리

전체 정책: `docs/terraform-principles.md` → **EKS 관리형 Add-on** 섹션 참조.

### 현재 고정 버전 (EKS 1.33 / ap-northeast-2 / 2026-05-31 조회)

| Add-on | 고정 버전 | EKS 권장 여부 |
|--------|-----------|--------------|
| vpc-cni | `v1.20.5-eksbuild.1` | default |
| kube-proxy | `v1.33.10-eksbuild.2` | default |
| coredns | `v1.12.4-eksbuild.10` | default |

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

- **`aws_security_group` 인라인 블록 금지**: `ingress {}`/`egress {}` 블록 대신 별도 리소스를 사용한다.
- **모듈 소유 SG**: 공식 모듈이 생성·소유하는 SG에 외부에서 규칙을 주입하지 않는다. 모듈이 제공하는 파라미터(`node_security_group_additional_rules` 등)로 관리한다.
- **커스텀 모듈 소유 SG**: `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` 별도 리소스로 선언한다.

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

EKS 클러스터, 시스템 노드 그룹, bootstrap addon(vpc-cni, kube-proxy, coredns)을
단일 실행 환경(`environments/.../eks/`)에서 함께 관리한다.

이유:
- 세 컴포넌트는 하나의 구축 시퀀스로 묶여 lifecycle이 동일하다.
- 별도 폴더로 분리하면 apply 순서 강제 및 운영 혼동이 발생한다.
- coredns(Deployment)는 노드 없이 설치 시 Pod 스케줄 불가로 장시간 CREATING 상태가 된다.
  vpc-cni·kube-proxy(DaemonSet)와 달리 노드가 준비된 후에 ACTIVE가 된다.

Karpenter, LBC 등 애플리케이션 레벨 addon은 클러스터 구축 후 독립 운영하므로
별도 실행 환경으로 분리한다.
