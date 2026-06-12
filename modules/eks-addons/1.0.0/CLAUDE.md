# modules/eks-addons 설계 원칙

## 이 모듈이 관리하는 애드온 (4종)

| 애드온 | 설치 방법 | IAM 방식 |
|--------|-----------|---------|
| aws-load-balancer-controller | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |
| external-dns | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |
| metrics-server | Helm (eks-blueprints-addons) | 없음 |
| karpenter | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |

> EBS CSI Driver는 Bootstrap 애드온으로 분류되어 `modules/eks`에서 관리한다.
> kube-prometheus-stack은 Phase 6에서 별도 추가 예정.

---

## 고정 버전 (2026-06-09 기준)

| 애드온 | 고정 버전 |
|--------|-----------|
| aws-ia/eks-blueprints-addons (Terraform 모듈) | `~> 1.23.0` |
| aws-load-balancer-controller (Helm chart) | `3.4.0` |
| external-dns (Helm chart) | `1.14.5` |
| metrics-server (Helm chart) | `3.12.2` |
| karpenter (Helm chart) | `1.12.1` |

---

## IAM 전략: IRSA (blueprints가 강제하는 방식)

이 모듈의 IAM 연동은 IRSA를 사용한다. **blueprints 모듈이 IRSA만 지원하기 때문이다.**
Pod Identity 전환 계획이 공식적으로 없어 blueprints를 사용하는 한 IRSA를 벗어날 수 없다.
(github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/289 — Closed as Not Planned)

blueprints 외부에서 관리하는 `aws_eks_addon`(EBS CSI)은 Pod Identity를 사용한다.
IAM 방식 선택 기준: blueprints 사용 → IRSA / blueprints 미사용 → Pod Identity.

blueprints 모듈에 `oidc_provider_arn`을 전달하면 각 애드온의 IAM Role 생성과
Helm values `serviceAccount.annotations` 주입을 내부에서 자동 처리한다.

---

## AWS 리소스 네이밍 규칙

blueprints의 기본값(`role_name_use_prefix = true`)은 `{name}-{random}` 형태로 IAM 리소스를 생성한다.
멀티 클러스터 환경에서 식별이 어려우므로 이 모듈은 모든 IAM 리소스에 고정 이름을 사용한다.

**네이밍 패턴**: `{cluster_name}-{addon}-{suffix}`

| 리소스 | 이름 패턴 | 예시 |
|--------|-----------|------|
| Karpenter Controller IRSA Role | `{cluster_name}-karpenter-controller-irsa` | `eks-practice-develop-karpenter-controller-irsa` |
| Karpenter Controller IAM Policy | `{cluster_name}-karpenter-controller-irsa` | 동일 |
| Karpenter Node IAM Role | `{cluster_name}-karpenter-node` | `eks-practice-develop-karpenter-node` |
| Karpenter Node Instance Profile | `{cluster_name}-karpenter-node` | 동일 (Role 이름 따라감) |
| Karpenter SQS 인터럽션 큐 | `{cluster_name}-karpenter` | `eks-practice-develop-karpenter` |
| LBC IRSA Role | `{cluster_name}-lbc-irsa` | `eks-practice-develop-lbc-irsa` |
| ExternalDNS IRSA Role | `{cluster_name}-external-dns-irsa` | `eks-practice-develop-external-dns-irsa` |

**접미사 의미**:
- `-irsa`: Pod ServiceAccount가 assume하는 IAM Role (IRSA 목적)
- `-node`: EC2 노드 인스턴스가 assume하는 IAM Role (노드 부트스트랩 목적)
- 접미사 없음: SQS 큐 등 IAM Role이 아닌 AWS 리소스

**변경 불가 리소스**: Karpenter EventBridge Rules(`Karpenter-{Event}-{random}`)는 blueprints 내부 하드코딩으로 변경 불가.

**ExternalDNS IAM 비생성 조건**: `external_dns_route53_zone_arns = []`이면 blueprints가 IAM Role을 생성하지 않는다. zone ARNs 설정 시 고정 이름으로 생성되도록 `role_name`을 미리 선언해둔다.

---

## 조건부 설치 패턴

`enable_external_dns`, `enable_karpenter` 변수로 각 애드온을 활성화/비활성화한다.
blueprints 모듈의 `enable_*` 파라미터에 직접 전달된다.

---

## Karpenter NodeClass / NodePool

blueprints는 Karpenter 컨트롤러 IAM Role, SQS 인터럽션 큐, EventBridge Rule, Helm chart를
자동으로 설치한다. **EC2NodeClass와 NodePool은 Kubernetes 리소스**이므로 이 모듈에서 관리하지 않는다.
클러스터 apply 이후 별도로 적용한다.

---

## Karpenter 노드 IAM Role의 EKS Access Entry

blueprints의 karpenter 서브모듈은 노드 IAM Role/Instance Profile(`{cluster_name}-karpenter-node`)만
생성하고 **EKS Access Entry는 생성하지 않는다**. `authentication_mode`가 `API` 또는
`API_AND_CONFIG_MAP`인 클러스터에서는 access entry가 없는 IAM Role의 EC2 인스턴스는 kubelet이
`Unauthorized` 오류로 노드 등록에 실패한다 (managed node group은 access entry가 자동 생성되지만
Karpenter 노드 Role은 수동 등록이 필요).

이 모듈은 `enable_karpenter = true`일 때 `aws_eks_access_entry.karpenter_node`
(type=`EC2_LINUX`)를 함께 생성해 이 문제를 방지한다. `EC2_LINUX` 타입은
`system:nodes` / `system:bootstrappers` 그룹 매핑이 내장되어 있어 별도 access policy
association이 필요 없다.

---

## External DNS 조건부 설치 패턴

```hcl
enable_external_dns = var.enable_external_dns  # blueprints 파라미터로 전달
```

---

## 버전 업그레이드 절차

```bash
helm repo update
helm search repo <chart-name> --versions
```

최신 stable 버전 확인 후 `environments/.../eks-addons/locals.tf`의 chart version 값을 수정한다.

참고 링크:
- LBC: https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
- ExternalDNS: https://github.com/kubernetes-sigs/external-dns/releases
- Metrics Server: https://github.com/kubernetes-sigs/metrics-server/releases
- Karpenter: https://github.com/aws/karpenter-provider-aws/releases
