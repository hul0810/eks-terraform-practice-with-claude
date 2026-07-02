# modules/eks-addons 설계 원칙

## 이 모듈이 관리하는 애드온 (10종)

| 애드온 | 설치 방법 | IAM 방식 | 활성화 조건 |
|--------|-----------|---------|------------|
| aws-load-balancer-controller | Helm (eks-blueprints-addons) | IRSA | 기본 활성 |
| external-dns | Helm (eks-blueprints-addons) | IRSA | 기본 활성 |
| metrics-server | Helm (eks-blueprints-addons) | 없음 | 기본 활성 |
| external-secrets | Helm (eks-blueprints-addons) | IRSA(스코프는 호출자가 명시, 미지정 시 blueprints 기본 와일드카드) | `enable_external_secrets=true` |
| karpenter | Helm (eks-blueprints-addons) | IRSA | 기본 활성 |
| argocd | Helm (eks-blueprints-addons) | 없음 | 기본 활성 |
| argo-rollouts | Helm (eks-blueprints-addons) | 없음 | `enable_argo_rollouts=true` |
| opentelemetry-operator | Helm (직접) | 없음 | `enable_otel_spoke_collector=true` |
| otel-spoke-node (DaemonSet) | OpenTelemetryCollector CRD | 없음 | `enable_otel_spoke_collector=true` |
| otel-spoke-singleton (Deployment) | OpenTelemetryCollector CRD | 없음 | `enable_otel_spoke_collector=true` |

> **External Secrets Operator(2026-07-02 기준)**: AWS EKS 관리형 add-on 카탈로그와 커뮤니티 add-on
> 카탈로그 어디에도 ESO가 없어 Bootstrap(`aws_eks_addon`)으로 관리할 수 없다 —
> Helm(blueprints)만이 유일한 설치 경로다.
> IAM 스코프(`external_secrets_ssm_parameter_arns`, `external_secrets_kms_key_arns`)는 이 모듈이 호출자에게
> 위임한다 — 아래 "IAM 전략" 섹션의 "External Secrets Operator IAM 스코프 좁히기" 참조.
> SecretStore/ClusterSecretStore, ExternalSecret CR은 이 모듈의 관리 범위가 아니다 — 환경 root module에서
> 관리한다(예: `monitoring/environments/ap-northeast-2/shared/eks-addons/main.tf`).

> EBS CSI Driver와 Secrets Store CSI Driver + ASCP는 Bootstrap 애드온으로 분류되어 `modules/eks`에서 관리한다.
> cert-manager도 Bootstrap 애드온(`modules/eks`) — OTel Operator의 webhook 인증서 발급에 활용된다.

---

## 고정 버전 (2026-06-17 기준)

| 애드온 | 고정 버전 |
|--------|-----------|
| aws-ia/eks-blueprints-addons (Terraform 모듈) | `~> 1.23.0` |
| aws-load-balancer-controller (Helm chart) | `3.4.0` |
| external-dns (Helm chart) | `1.14.5` |
| metrics-server (Helm chart) | `3.12.2` |
| karpenter (Helm chart) | `1.12.1` |
| argo-cd (Helm chart) | `9.5.21` |
| argo-rollouts (Helm chart) | `2.38.1` |
| external-secrets (Helm chart) | `2.7.0` |

---

## IAM 전략: IRSA (blueprints가 강제하는 방식)

이 모듈의 IAM 연동은 IRSA를 사용한다. **blueprints 모듈이 IRSA만 지원하기 때문이다.**
Pod Identity 전환 계획이 공식적으로 없어 blueprints를 사용하는 한 IRSA를 벗어날 수 없다.
(github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/289 — Closed as Not Planned)

blueprints 외부에서 관리하는 `aws_eks_addon`(EBS CSI)은 Pod Identity를 사용한다.
IAM 방식 선택 기준: blueprints 사용 → IRSA / blueprints 미사용 → Pod Identity.

blueprints 모듈에 `oidc_provider_arn`을 전달하면 각 애드온의 IAM Role 생성과
Helm values `serviceAccount.annotations` 주입을 내부에서 자동 처리한다.

### External Secrets Operator IAM 스코프 좁히기

blueprints의 `external_secrets_ssm_parameter_arns` / `external_secrets_secrets_manager_arns` /
`external_secrets_kms_key_arns` 변수는 **기본값이 이미 와일드카드**다
(`arn:aws:ssm:*:*:parameter/*`, `arn:aws:kms:*:*:key/*` 등 — blueprints 소스 확인 완료).
이 프로젝트는 비용 정책과 무관하게 "실무 협업 기준"(`docs/terraform-principles.md`)에 따라
IAM 최소 권한 원칙을 지키므로, 이 모듈이 `external_secrets_ssm_parameter_arns` /
`external_secrets_kms_key_arns` 변수를 새로 노출해 호출자가 명시적으로 스코프를 좁히도록 강제한다
(`external_secrets_secrets_manager_arns`는 이 프로젝트가 SSM Parameter Store만 사용하므로 아직 미노출).

**"빈 리스트 = blueprints 기본값 유지"를 재현하는 방법**: blueprints 내부는
`length(var.external_secrets_ssm_parameter_arns) > 0 ? [statement] : []` 형태의 dynamic block으로
IAM 정책 statement를 생성한다. 즉 빈 리스트를 그대로 전달하면 "와일드카드 허용"이 아니라
"해당 정책 statement 자체가 생성되지 않아 권한 없음"으로 귀결된다(ExternalDNS의
`external_dns_route53_zone_arns=[]` → "IAM Role 자체 미생성"과는 다른 메커니즘).
이 모듈은 `main.tf`에서 삼항 연산자로 빈 리스트일 때 blueprints 기본 와일드카드
(`arn:aws:ssm:*:*:parameter/*`, `arn:aws:kms:*:*:key/*`)를 명시적으로 대신 전달해
"미지정 시 동작"을 재현한다.

실제 스코프 확정은 각 환경 root module의 몫이다(예: `monitoring/.../eks-addons/locals.tf`가
`data.aws_caller_identity`로 계정 ID를, `data.aws_kms_alias.ssm_default`(`alias/aws/ssm`)로
SSM SecureString 기본 키 ARN을 조회해 SSM parameter path prefix + 해당 KMS 키로 스코프를 좁힌다).

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

### 크로스 계정 Route53 접근 (external_dns_assume_role_arn)

Route53 zone이 클러스터와 다른 계정에 있을 때(예: monitoring 클러스터가 workload 계정의
zone을 관리) `external_dns_assume_role_arn`에 위임 Role ARN을 전달하면 helm `set`으로
`extraArgs[0]=--aws-assume-role=<arn>`이 주입된다.

**주의(플래그 이름 함정)**: external-dns 바이너리의 실제 CLI 플래그는 `--aws-assume-role`이다.
`--aws-assume-role-arn`처럼 직관적으로 보이는 이름을 쓰면 `flag parsing error: unknown long
flag`로 pod가 즉시 CrashLoopBackOff에 빠진다. 플래그 이름 변경 시 `kubectl logs`로 helm
release 자체가 아니라 컨테이너 시작 로그를 확인해야 원인을 바로 찾을 수 있다.

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

### admin 초기 패스워드 설정 (argocd_admin_password_bcrypt)

`argocd_admin_password_bcrypt` 변수에 bcrypt 해시를 전달하면 Helm values
`configs.secret.argocdServerAdminPassword`로 주입되어 ArgoCD 배포 시 admin 패스워드가 고정된다.
비워두면 ArgoCD가 자동 생성한 시크릿을 사용하고 `argocd-initial-admin-secret`에서 확인해야 한다.

각 환경 root module(`monitoring/`, `project/environments/{develop,production}/.../eks-addons/`)은 이 값을
로컬 `secret.auto.tfvars` 대신 SSM Parameter Store(Standard tier, 무료)의
`data "aws_ssm_parameter"`로 조회하여 `local.eks_addons.argocd_admin_password_bcrypt`에 담아 모듈로 전달한다
(경로: `/eks-practice/{environment}/eks-addons/argocd-admin-password-bcrypt`, SecureString).
`operator_ip_cidr`도 동일한 방식으로 `/eks-practice/{environment}/eks-addons/operator-ip-cidr`(String)에서 조회한다.
값을 등록·갱신할 때마다 root module의 tfvars 파일을 손으로 고칠 필요가 없다는 것이 이 방식의 장점이다.
모듈 자체는 여전히 plain string 변수를 받으므로 이 모듈의 인터페이스에는 영향이 없다.

**반드시 사전 계산된 고정 해시를 사용해야 한다.**
Terraform `bcrypt()` 함수는 호출마다 다른 salt를 생성하여 매 apply마다 `argocd-secret`이
업데이트되고 ArgoCD server pod가 재시작된다.

해시 생성:
```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'PASSWORD', bcrypt.gensalt()).decode())"
```

패스워드 변경 시 새 해시와 함께 `main.tf`의 `argocdServerAdminPasswordMtime` 타임스탬프도
반드시 갱신해야 ArgoCD가 변경을 감지하고 반영한다.

### app-controller replica를 늘리지 않는 이유

ArgoCD의 `application-controller`(StatefulSet)는 replica를 늘리면 자동으로
Application을 분산 처리하지 않는다 — sharding을 위해 `controller.replicas`와
함께 shard 할당 알고리즘 설정이 추가로 필요하다. 이 단계에서는 sharding을
구성하지 않으므로 `controller.replicas`를 변경하지 않고 기본값(1)을 유지한다.
Application 수가 늘어나 컨트롤러가 병목이 되면 향후 단계에서 sharding을 도입한다.

---

## OTel Spoke Collector (Phase 5)

`enable_otel_spoke_collector = true`로 활성화하면 dev/prd 클러스터에서 OTel Hub-Spoke 아키텍처의 spoke 역할을 수행한다.

### 배포 구성

| 리소스 | 모드 | 수집 대상 |
|--------|------|----------|
| `otel-spoke-node` (`OpenTelemetryCollector` CRD) | DaemonSet | 노드 메트릭(kubeletstats) + 컨테이너 로그(filelog) |
| `otel-spoke-singleton` (`OpenTelemetryCollector` CRD) | Deployment (1 replica) | K8s 오브젝트 메트릭(k8s_cluster) + 앱 트레이스(otlp) |
| `opentelemetry-operator` (Helm) | Deployment | OTel Operator — 위 CRD를 해석하여 Collector Pod 생성 |

### k8s_cluster receiver를 DaemonSet에서 분리한 이유

`k8s_cluster` receiver는 K8s API 서버를 폴링하여 Deployment, Pod, Node 등의 상태 메트릭을 수집한다.
DaemonSet에 포함하면 노드 수만큼 동일한 메트릭이 중복 수집되어 Mimir에 n배 적재된다.
단일 Deployment(`otel-spoke-singleton`)에 격리하여 클러스터당 1회만 수집한다.

### 사전 조건

1. **cert-manager** — OTel Operator의 admission webhook 인증서 발급에 필요. Bootstrap 애드온으로 `modules/eks`에서 관리.
2. **VPC Peering** — `otel_gateway_endpoint`가 가리키는 monitoring NLB가 VPC Peering을 통해 라우팅 가능해야 함.
   dev/prd vpc의 `vpc_peering_routes`에 monitoring VPC CIDR(10.12.0.0/16)을 추가한 후 apply.
3. **OTel Operator 선설치** — `kubernetes_manifest` CRD 리소스는 plan 시점에 CRD 스키마를 조회한다.
   Operator 설치 전 `plan`은 실패할 수 있으므로 `helm_release.otel_operator_spoke` apply 후 `plan`을 재실행한다.

### 활성화 절차

```hcl
# eks-addons/locals.tf
enable_otel_spoke_collector       = true
otel_gateway_endpoint             = "internal-xxxx.ap-northeast-2.elb.amazonaws.com:4317"
otel_spoke_operator_chart_version = "0.76.1"
```

`otel_gateway_endpoint`는 `monitoring/environments/ap-northeast-2/shared/observability/` 의
`terraform output otel_gateway_nlb_hostname` 값에 `:4317`을 붙인 것이다.

### GitOps 전환 계획 (Phase 6)

현재 Phase 5에서는 Terraform `helm_release` + `kubernetes_manifest`로 직접 관리한다.
Phase 6에서 ArgoCD Hub-Spoke 구성이 완료되면 아래 리소스를 ArgoCD Application으로 이관한다:

| 현재 Terraform 리소스 | 이관 대상 (`devops-manifest` 경로) |
|----------------------|----------------------------------|
| `helm_release.otel_operator_spoke` | `observability/otel-operator/` |
| `kubernetes_manifest.otel_spoke_node` | `observability/otel-collectors/node/` |
| `kubernetes_manifest.otel_spoke_singleton` | `observability/otel-collectors/singleton/` |

이관 시 Terraform에서 해당 리소스를 제거하고 `terraform state rm`으로 state에서도 분리한다.

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
