# modules/eks-addons 설계 원칙

## 이 모듈이 관리하는 애드온 (5종)

| 애드온 | 설치 방법 | IAM 방식 |
|--------|-----------|---------|
| aws-load-balancer-controller | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |
| external-dns | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |
| metrics-server | Helm (eks-blueprints-addons) | 없음 |
| karpenter | Helm (eks-blueprints-addons) | IRSA (blueprints 자동 처리) |
| argocd | Helm (eks-blueprints-addons) | 없음 |

> EBS CSI Driver는 Bootstrap 애드온으로 분류되어 `modules/eks`에서 관리한다.
> kube-prometheus-stack은 Phase 6에서 별도 추가 예정.

---

## 고정 버전 (2026-06-12 기준)

| 애드온 | 고정 버전 |
|--------|-----------|
| aws-ia/eks-blueprints-addons (Terraform 모듈) | `~> 1.23.0` |
| aws-load-balancer-controller (Helm chart) | `3.4.0` |
| external-dns (Helm chart) | `1.14.5` |
| metrics-server (Helm chart) | `3.12.2` |
| karpenter (Helm chart) | `1.12.1` |
| argo-cd (Helm chart) | `9.5.21` |

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
| Karpenter Controller IRSA Role | `{cluster_name}-karpenter-controller-irsa` | `eks-practice-dev-karpenter-controller-irsa` |
| Karpenter Controller IAM Policy | `{cluster_name}-karpenter-controller-irsa` | 동일 |
| Karpenter Node IAM Role | `{cluster_name}-karpenter-node` | `eks-practice-dev-karpenter-node` |
| Karpenter Node Instance Profile | `{cluster_name}-karpenter-node` | 동일 (Role 이름 따라감) |
| Karpenter SQS 인터럽션 큐 | `{cluster_name}-karpenter` | `eks-practice-dev-karpenter` |
| LBC IRSA Role | `{cluster_name}-lbc-irsa` | `eks-practice-dev-lbc-irsa` |
| ExternalDNS IRSA Role | `{cluster_name}-external-dns-irsa` | `eks-practice-dev-external-dns-irsa` |

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

## ArgoCD 설치 (Phase 5-1)

GitOps 전환(Phase 5)의 시작점. 이후 단계(5-2~5-5)에서 `create_kubernetes_resources = false`로
전환되어 Application/AppProject 등을 ArgoCD 자체가 동기화하게 되지만, 5-1 단계에서는
일반적인 Helm 애드온 추가 패턴을 따른다.

### IAM 미생성

ArgoCD는 AWS API를 호출하지 않으므로 IRSA/Pod Identity가 불필요하다. `metrics-server`와
동일한 패턴 — `enable_argocd`만 blueprints에 전달하고 별도 IAM Role을 선언하지 않는다.

### dex(SSO) / notifications 비활성화

`values.dex.enabled = false`, `values.notifications.enabled = false`로 명시 비활성화한다.
SSO Provider(OIDC/SAML)와 알림 채널(Slack 등)이 아직 구성되지 않은 상태이므로, 미구성
상태에서 활성화하면 컨테이너가 CrashLoop 또는 무의미한 리소스를 점유한다. 필요 시
이후 단계에서 SSO/알림 채널 구성과 함께 활성화한다.

### argocd_ha_enabled 토글

`argocd_ha_enabled = true`이면:
- `redis-ha.enabled = true` — Redis를 단일 인스턴스에서 Sentinel 기반 HA 구성으로 전환
- `server`, `repoServer`, `applicationSet`의 replica를 `replica_counts.argocd_server`(기본 2)로 증설

`argocd_ha_enabled = false`이면 위 컴포넌트 모두 단일 replica, redis-ha 비활성 (단일 Redis Pod).

dev는 `false`(단일 시스템 노드에 redis-ha 등 추가 Pod를 배치할 여유가 없음 — 비용 절감),
production은 `true`(server/repoServer/applicationSet replica=2 + redis-ha)로 설정한다.

### redis-ha tolerations를 global과 별도로 명시하는 이유

argo-cd 차트의 `global.tolerations`는 server/repoServer/controller/applicationSet에는
전파되지만, `redis-ha` 서브차트(bitnami/redis-ha 기반)는 자체 values 스키마를 사용하여
global 값 전파가 보장되지 않는다. 따라서 `redis-ha.tolerations`를 별도로 명시해
시스템 노드(CriticalAddonsOnly taint)에 정상적으로 스케줄되도록 한다.

### ALB Ingress 접근 제어 (argocd_ingress_allowed_cidrs)

`dex.enabled = false`로 SSO가 비활성화되어 있어 ArgoCD server는 기본 admin 계정의
비밀번호만으로 인증한다. 인터넷에 노출된 ALB에 접근 제어가 없으면 admin 계정에
대한 무차별 대입 공격에 노출되므로, `alb.ingress.kubernetes.io/inbound-cidrs`
어노테이션으로 ALB Security Group의 inbound를 허용 CIDR로 제한한다.
`argocd_ingress_enabled = true`일 때 `argocd_ingress_allowed_cidrs`에 허용할
CIDR(예: 작업자 공인 IP `/32`)을 반드시 지정한다. SSO 등 별도 인증 체계가
구성되면 이 제한을 완화할 수 있다.

### ALB 이름 커스터마이징 (argocd_ingress_alb_name)

`alb.ingress.kubernetes.io/load-balancer-name` 어노테이션으로 ALB 이름을
`{project}-argocd{name_suffix}-alb` 패턴(예: develop `eks-practice-argocd-dev-alb`)으로
고정한다. AWS ALB 이름 제한(최대 32자, 영문/숫자/하이픈)을 따라야 한다.
production은 `name_suffix`가 빈 문자열이므로 `eks-practice-argocd-alb`가 된다.

**주의(불변 속성)**: 이 어노테이션은 ALB **최초 생성 시점에만** 적용된다.
이미 생성된 ALB에 대해 값을 변경해도 AWS ALB API에는 이름 변경 기능이 없어
LBC는 기존 ALB를 그대로 유지한 채 "successfully reconciled"로만 기록한다.
기존 ALB의 이름을 바꾸려면 `argocd_ingress_enabled`를 `false`로 설정해
`terraform apply`(ALB 삭제) 후 다시 `true`로 설정해 `terraform apply`
(새 이름으로 ALB 재생성)하는 2단계 토글이 필요하다. 이 과정에서 다운타임과
ExternalDNS의 Route53 레코드 재연결이 발생한다.

### app-controller replica를 늘리지 않는 이유

ArgoCD의 `application-controller`(StatefulSet)는 replica를 늘리면 자동으로
Application을 분산 처리하지 않는다 — sharding을 위해 `controller.replicas`와
함께 shard 할당 알고리즘 설정이 추가로 필요하다. 이 단계에서는 sharding을
구성하지 않으므로 `controller.replicas`를 변경하지 않고 기본값(1)을 유지한다.
Application 수가 늘어나 컨트롤러가 병목이 되면 향후 단계에서 sharding을 도입한다.

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
