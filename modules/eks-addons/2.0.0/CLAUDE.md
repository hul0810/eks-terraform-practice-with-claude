# modules/eks-addons 설계 원칙

## 1.0.0 → 2.0.0 변경 사항 (2026-07-17)

`1.0.0`을 그대로 두고 새 버전으로 분리한 이유는 이 변경이 **파괴적**이기 때문이다 —
아래 변경은 호출자(환경 root module)가 자신의 변수 값을 하나도 안 바꿔도 기존 ArgoCD·LBC
Helm release의 Terraform state 주소가 바뀌어 destroy→recreate를 유발한다(review-terraform에서
Critical로 발견).

| 항목 | 1.0.0 | 2.0.0 |
|------|-------|-------|
| 내부 `aws-ia/eks-blueprints-addons` 호출 개수 | 1개 (`eks_blueprints_addons`) | 2개 — `eks_blueprints_addons`(rest) / `eks_blueprints_addons_gitops`(GitOps 이관 완료 addon, IAM만 유지). ArgoCD는 이 벤더 모듈 밖으로 완전히 빠졌다(아래 참조) |
| ArgoCD | `eks_blueprints_addons` 안에서 다른 addon과 함께 관리 | `module "gitops_bridge_bootstrap"`(`gitops-bridge-dev/gitops-bridge/helm`)로 분리 — GitOps Bridge 최종 전환 스위치(`create_kubernetes_resources`)와 무관하게 항상 Helm까지 Terraform이 관리(부트스트랩 예외). **2026-07-19 추가 변경**: 이 인스턴스는 원래 `aws-ia/eks-blueprints-addons`의 `eks_blueprints_addons_argocd`였으나, 그 wrapper가 ArgoCD 자리에서만 IRSA 관련 인자(`create_role`/`oidc_providers` 등)를 forward하지 않는다는 걸 발견해 `gitops-bridge-dev/gitops-bridge/helm`로 교체했다 — 상세 이유는 `temp/gitops-bridge-terraform-notes.md` 7~11번 참고. ArgoCD 자신의 IRSA(IAM Role/Access Entry/RBAC)는 이 교체와 무관하게 root의 `gitops-bridge-irsa.tf`에 계속 손코드로 남는다(어느 vendor도 이건 대신 안 해준다) |
| aws-load-balancer-controller, external-dns, external-secrets, karpenter | `eks_blueprints_addons` 안에서 IAM+Helm 모두 관리 | `eks_blueprints_addons_gitops`로 분리 — IAM(IRSA, karpenter는 노드 IAM Role+SQS+EventBridge까지)만 Terraform 유지, Helm release는 ArgoCD(devops-manifest)가 관리. 이 표는 2026-07-17 LBC 단독 이관 시점 기준으로 작성됐으나 2026-07-18 나머지 3개도 동일 패턴으로 이관 완료 |
| 신규 변수 | — | `create_kubernetes_resources`(기본 `true`, "rest" 인스턴스 전용 — GitOps Bridge로 이관 안 된 addon 전체의 Helm 생성을 한 번에 끄는 최종 전환 스위치) |
| `outputs.lbc_role_arn`/`karpenter_role_arn`/`karpenter_node_iam_role_name`/`external_dns_role_arn`/`external_secrets_role_arn` | `module.eks_blueprints_addons.*` 참조 | `module.eks_blueprints_addons_gitops.*` 참조로 변경 |

**전환 절차**(develop/production이 나중에 `2.0.0`으로 옮길 때): 아래 "GitOps Bridge: 모듈
인스턴스 3분할" 절의 "addon을 이관할 때 state 이전 절차"를 그대로 따른다 — LBC/ArgoCD를
ArgoCD Application으로 먼저 sync 검증한 뒤, `terraform state mv`/`state rm`으로 정리하고
source를 `2.0.0`으로 바꾼다. LBC/ArgoCD 둘 다 손대지 않은 환경이라면 `state` 작업 없이
source만 바꿔도 되는지는 **반드시 `terraform plan`으로 destroy 항목이 없는지 먼저 확인** —
1.0.0의 `enable_argocd`/`enable_aws_load_balancer_controller`가 `true`인 상태로 그대로
`2.0.0`을 가리키면 이 표의 인스턴스 재배치 때문에 여전히 destroy→recreate가 발생한다.

---

## 이 모듈이 관리하는 애드온 (10종)

| 애드온 | 설치 방법 | IAM 방식 | 활성화 조건 |
|--------|-----------|---------|------------|
| aws-load-balancer-controller | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-3)**, IAM만 Terraform 유지 | IRSA | 기본 활성 |
| external-dns | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-4)**, IAM만 Terraform 유지 | IRSA | 기본 활성 |
| metrics-server | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-2)** | 없음 | 기본 활성 |
| external-secrets | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-4)**, IAM만 Terraform 유지 | IRSA(스코프는 호출자가 명시, 미지정 시 blueprints 기본 와일드카드) | `enable_external_secrets=true` |
| karpenter | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-4)**, IAM(컨트롤러 IRSA+노드 IAM Role+SQS+EventBridge)만 Terraform 유지 | IRSA | 기본 활성 |
| argocd | Helm (`gitops-bridge-dev/gitops-bridge/helm`) — **GitOps Bridge 대상에서 영구 제외**(부트스트랩 예외, 아래 참조) | 없음(단, Hub 자신의 IRSA는 root `gitops-bridge-irsa.tf`에 손코드로 별도 존재) | 기본 활성 |
| argo-rollouts | ~~Helm~~ → **ArgoCD(GitOps Bridge, Phase 6-4)** | 없음 | `enable_argo_rollouts=true`(모니터링은 GitOps 이관 후 `false` — 아래 1.0.0→2.0.0 표 참고) |
| opentelemetry-operator | Helm (직접) | 없음 | `enable_otel_spoke_collector=true` |
| otel-spoke-node (DaemonSet) | OpenTelemetryCollector CRD | 없음 | `enable_otel_spoke_collector=true` |
| otel-spoke-singleton (Deployment) | OpenTelemetryCollector CRD | 없음 | `enable_otel_spoke_collector=true` |

> **monitoring 기준(2026-07-18)**: 위 addon 중 argocd를 제외한 전부(LBC/external-dns/
> metrics-server/external-secrets/karpenter/argo-rollouts)가 GitOps Bridge 이관을
> 완료했다. develop/production은 아직 `1.0.0`(전부 Terraform Helm)을 쓰므로 이 표는
> `2.0.0`을 실제로 참조하는 환경(현재 monitoring만) 기준이다.

> **"Helm (eks-blueprints-addons)"의 실제 의미(Phase 6 이후)**: 아직 GitOps Bridge로 이관되지
> 않은 addon만 이 모듈이 Helm release까지 직접 설치한다. "ArgoCD(GitOps Bridge)"로 표시된
> addon은 이 모듈이 IAM(필요한 경우)만 유지하고 실제 Helm release는
> `eks-practice-devops-manifest` 저장소의 ArgoCD Application이 관리한다 — 아래 "GitOps Bridge:
> 모듈 인스턴스 3분할" 절 참조.

> **External Secrets Operator(2026-07-02 기준)**: AWS EKS 관리형 add-on 카탈로그와 커뮤니티 add-on
> 카탈로그 어디에도 ESO가 없어 Bootstrap(`aws_eks_addon`)으로 관리할 수 없다 —
> Helm(blueprints)만이 유일한 설치 경로다.
> IAM 스코프(`external_secrets_ssm_parameter_arns`, `external_secrets_kms_key_arns`)는 이 모듈이 호출자에게
> 위임한다 — 아래 "IAM 전략" 섹션의 "External Secrets Operator IAM 스코프 좁히기" 참조.
> SecretStore/ClusterSecretStore, ExternalSecret CR은 이 모듈의 관리 범위가 아니다 — 원래는
> 환경 root module(`monitoring/environments/ap-northeast-2/shared/eks-addons/*.tf`)이
> Terraform으로 직접 관리했으나, 2026-07-18 Phase 6-4로 monitoring의 SecretStore/
> ClusterSecretStore/ExternalSecret 전부가 devops-manifest 저장소의 ArgoCD Application으로
> 이관됐다 — monitoring root에는 이제 이 CR 종류가 전혀 없다(ArgoCD 자신의 repo-creds만
> 예외로 `kubernetes_secret_v1`을 쓰며 ESO 자체를 우회한다). develop/production은 아직
> `1.0.0`을 쓰고 이런 CR을 애초에 만들지 않으므로 이 문단은 사실상 monitoring의 과거
> 상태를 설명하는 참고용으로만 남는다.

> EBS CSI Driver와 Secrets Store CSI Driver + ASCP는 Bootstrap 애드온으로 분류되어 `modules/eks`에서 관리한다.
> cert-manager도 Bootstrap 애드온(`modules/eks`) — OTel Operator의 webhook 인증서 발급에 활용된다.

---

## GitOps Bridge: 모듈 인스턴스 3분할 (Phase 6, 2026-07-17~)

`aws-ia/terraform-aws-eks-blueprints-addons`는 addon마다 별도 스위치(`enable_metrics_server`
등)를 두면서도, "Kubernetes 리소스(Helm release)를 실제로 만들지 여부"를 결정하는
`create_kubernetes_resources` 변수는 그 모듈 **인스턴스 전체**에 걸쳐 단 하나뿐이다 — 소스를
직접 확인한 결과 argocd/metrics_server/aws_load_balancer_controller 등 26개 addon 서브모듈이
전부 `create_release = var.create_kubernetes_resources`로 예외 없이 같은 변수를 참조한다.
addon마다 다르게 줄 수 있는 여지가 소스에 없다.

이 프로젝트는 GitOps Bridge(Phase 6)로 addon을 ArgoCD 관리로 하나씩 이관하는데, 요구사항이
addon마다 다르다 — 그래서 `module "eks_blueprints_addons"`를 2개 인스턴스로 나누고,
ArgoCD는 별도 vendor 모듈 인스턴스(`gitops_bridge_bootstrap`)로 완전히 분리했다(`main.tf` 참조):

| 인스턴스 | 벤더 모듈 | `create_kubernetes_resources` | 담는 addon | 존재 이유 |
|---|---|---|---|---|
| `eks_blueprints_addons` | `aws-ia/eks-blueprints-addons` | `var.create_kubernetes_resources`(기본 `true`, monitoring은 `false`로 명시 고정) | 아직 이관 안 된 addon 전부 | "rest" — monitoring은 2026-07-18 기준 이 인스턴스에 연결된 addon(`enable_metrics_server`/`enable_argo_rollouts`)이 전부 `false`라 실질적으로 빈 인스턴스다. `create_kubernetes_resources = false`를 환경 root(`monitoring/.../eks-addons/main.tf`)에서 명시해 최종 정리 완료 — 이제 새 addon이 실수로 이 인스턴스에 추가돼도 Helm이 조용히 뜨지 않는다. develop/production은 아직 `1.0.0`이라 해당 없음 |
| `gitops_bridge_bootstrap` | `gitops-bridge-dev/gitops-bridge/helm` | 해당 없음(이 벤더는 이 변수 자체가 없음) | ArgoCD 설치 + GitOps Bridge Hub 부트스트랩(cluster Secret) | **부트스트랩 예외** — ArgoCD가 자기 자신을 GitOps로 관리할 수 없으므로 영원히 Terraform이 Helm까지 관리. `var.enable_argocd`가 `create`/`install`을 동시에 게이팅한다. `cluster`/`apps`는 `var.gitops_bridge_hub`(nullable)로 받는다 — null이면 이 클러스터는 spoke로 동작(develop/production이 나중에 이 모듈로 이관되면 이 값을 안 넘기면 된다). 원래 `aws-ia/eks-blueprints-addons`의 별도 인스턴스(`eks_blueprints_addons_argocd`)였으나 그 wrapper가 ArgoCD 자리에서 IRSA 인자를 forward하지 않아 교체했다(`temp/gitops-bridge-terraform-notes.md` 7~11번) |
| `eks_blueprints_addons_gitops` | `aws-ia/eks-blueprints-addons` | 항상 `false`로 고정 | GitOps Bridge로 이관 완료된 addon(LBC 등) | IAM은 유지하되 Helm release는 절대 만들지 않음 — ArgoCD가 그 자리를 대신함 |

### addon을 이관할 때 state 이전 절차

**`moved` 블록은 이 상황에 안 맞는다** — vendor 모듈 소스가 `enable_x` 값과 무관하게
`module "x" {...}`를 항상 선언해두므로(내부적으로 `create = var.enable_x`만 조건부),
addon을 다른 인스턴스로 옮겨도 Terraform은 원래 위치의 `module.x` 호출이 "여전히
선언되어 있다"고 판단해 `moved`를 `Error: Moved object still exists`로 거부한다.
명령형 `terraform state mv`/`state rm`으로 직접 옮겨야 한다.

**IAM이 필요 없는 addon(metrics-server 등)** — Terraform이 완전히 손을 뗀다:
```bash
terraform state rm 'module.eks_addons.module.eks_blueprints_addons.module.<addon>.helm_release.this[0]'
# 그리고 locals.tf에서 enable_<addon> = false 로 변경
```

**IAM이 필요한 addon(LBC 등)** — IAM은 유지, Helm만 이관:
```bash
# 1. IAM 리소스는 새 gitops 인스턴스로 이전 (실제 AWS 리소스 불변)
terraform state mv \
  'module.eks_addons.module.eks_blueprints_addons.module.<addon>.aws_iam_role.this[0]' \
  'module.eks_addons.module.eks_blueprints_addons_gitops.module.<addon>.aws_iam_role.this[0]'
terraform state mv \
  'module.eks_addons.module.eks_blueprints_addons.module.<addon>.aws_iam_policy.this[0]' \
  'module.eks_addons.module.eks_blueprints_addons_gitops.module.<addon>.aws_iam_policy.this[0]'
terraform state mv \
  'module.eks_addons.module.eks_blueprints_addons.module.<addon>.aws_iam_role_policy_attachment.this[0]' \
  'module.eks_addons.module.eks_blueprints_addons_gitops.module.<addon>.aws_iam_role_policy_attachment.this[0]'
# 2. Helm release는 Terraform 추적에서만 제거 (destroy 아님 — ArgoCD가 이미 인수한 뒤에만 실행)
terraform state rm \
  'module.eks_addons.module.eks_blueprints_addons.module.<addon>.helm_release.this[0]'
# 3. modules/eks-addons/1.0.0/main.tf에서 해당 addon 블록을
#    "rest" 인스턴스 → eks_blueprints_addons_gitops 인스턴스로 옮긴다
```

**순서가 중요하다 — 반드시 "ArgoCD sync 검증 → Terraform state 정리" 순서를 지킨다.**
Terraform 모듈 분리(2번 mv/rm)를 ArgoCD sync 전에 먼저 하면, "rest" 인스턴스에서 그 addon
블록이 사라지는 순간 Terraform이 기존 helm_release를 destroy하려 시도한다(ArgoCD가 아직
인수하기 전인데 `helm uninstall`이 실행되는 것) — 실제 다운타임으로 이어진다. sync 전 diff가
tracking annotation뿐인지 확인 → sync → 파드/ALB 등 정상 확인 → 그 다음에만 state 정리.

### Helm chart의 비결정적 필드 대응 (webhook 인증서 등)

일부 chart(예: aws-load-balancer-controller)는 `helm template`을 실행할 때마다 매번 새
자체서명 인증서(Secret + webhook `caBundle`)를 생성한다. Terraform의 `helm_release`는 입력값이
안 바뀌면 재렌더링을 안 해서 이 비결정성이 드러나지 않지만, ArgoCD는 sync할 때마다 항상
재렌더링하므로 매번 인증서가 바뀌어버린다 — 실제 사례로 다른 프로젝트에서 이 문제로
`connection reset by peer`가 반복 발생해 pod 재시작으로만 복구된 보고가 있다
(https://github.com/Twingate/kubernetes-operator/issues/893).

chart 자체의 `keepTLSSecret` 같은 옵션은 Helm `lookup` 함수에 의존하는데, **ArgoCD는 `lookup`을
지원하지 않는다**(공식 미해결 이슈: argoproj/argo-cd#5202, #21745) — 즉 chart 옵션으로는
해결이 안 된다. ArgoCD Application의 `ignoreDifferences` + `syncPolicy.syncOptions:
[RespectIgnoreDifferences=true]`로 해당 필드를 sync 대상에서 제외해야 한다.
`ignoreDifferences`만 설정하면 OutOfSync 판단에만 반영되고 실제 sync 시엔 그대로
덮어써지므로, `RespectIgnoreDifferences=true`를 빠뜨리면 문제가 그대로 재현된다.

webhook처럼 배열(`webhooks[]`)에 여러 항목이 있는 경우 `jsonPointers`는 특정 인덱스만
지정 가능해 배열 전체를 커버하지 못한다(예: LBC는 MutatingWebhookConfiguration에 6개,
ValidatingWebhookConfiguration에 3개 항목이 있어 `/webhooks/0/...`만으로는 부족했다) —
배열 전체를 커버하려면 `jqPathExpressions: ['.webhooks[]?.clientConfig.caBundle']`를 쓴다.

---

## 고정 버전 (2026-06-17 기준)

> **GitOps Bridge로 이관된 addon(monitoring 기준 argocd 제외 전부 — metrics-server,
> aws-load-balancer-controller, external-dns, external-secrets, karpenter, argo-rollouts)의
> chart 버전은 이 표가 아니라 `eks-practice-devops-manifest` 저장소가 실제 기준이다.**
> 아래 표의 값은 Terraform이 마지막으로 설치했던 시점의 기록이며, 이관 이후
> devops-manifest에서 버전을 올려도 이 표는 자동으로 갱신되지 않는다. develop/production은
> 아직 `1.0.0`(전부 Terraform Helm)이라 이 표가 그대로 실제 기준이다.

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
| rollout-extension (ArgoCD UI extension, GitHub Release 자산) | `v0.4.0` (`local.rollout_extension_version`) |

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

## Karpenter Spot capacity-type — EC2 Spot 서비스 연결 역할 권한 (2026-07-04)

`karpenter_node_pools`의 `capacity_types`에 `"spot"`을 포함하면(이 프로젝트의 `general`
NodePool 기본값), Karpenter controller가 `CreateFleet` 호출 시 계정에
`AWSServiceRoleForEC2Spot`(EC2 Spot 서비스 연결 역할)이 없으면 직접 생성을 시도한다.

**증상**: spot `nodeSelector`가 붙은 Pod이 `Pending`으로 멈추고, `kubectl describe pod`에는
`no instance type has the required offering`만 보여 "spot 재고 부족"처럼 오인하기 쉽다.
실제 원인은 `kubectl logs -n karpenter deployment/karpenter`에서 `CreateFleet` 관련 로그로만
확인된다:

```
AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials do not have
permission to create the service-linked role for EC2 Spot Instances.
```

**원인**: blueprints가 생성하는 Karpenter controller 기본 IAM 정책에는
`iam:CreateServiceLinkedRole`이 빠져있다. 서비스 연결 역할이 계정에 이미 있으면 문제가
없지만, 그 계정에서 EC2 Spot을 한 번도 사용한 적이 없으면(신규 계정 등) 이 역할 자체가
없어서 매번 생성 시도 → 권한 거부 → spot 인스턴스 요청 실패로 이어진다.

**해결 (2단계)**:

1. **즉시 우회(1회성, 계정 전체)**: 관리자 권한으로 서비스 연결 역할을 직접 생성한다.
   계정당 1개만 있으면 되므로 클러스터를 몇 번을 재생성해도 다시 필요 없다.
   ```bash
   aws iam create-service-linked-role --aws-service-name spot.amazonaws.com --profile <admin-profile>
   ```
2. **근본 수정(IaC)**: `karpenter` 블록에 blueprints의 `policy_statements` 확장 포인트로
   최소 권한 statement를 추가한다(`main.tf` 참고). 서비스 연결 역할 ARN과
   `iam:AWSServiceName=spot.amazonaws.com` 조건으로 스코프를 좁혀, 이 역할 생성 외에는
   아무 권한도 주지 않는다. 이 statement 덕분에 서비스 연결 역할이 없는 새 AWS 계정에
   이 프로젝트를 배포해도 Karpenter가 스스로 만들 수 있어 1번 단계 없이도 동작한다.

   **주의(필드명 함정)**: blueprints의 `policy_statements`는 `aws_iam_policy_document`
   data source의 `statement` 블록을 그대로 감싸지만, condition 블록 키는 `condition`이
   아니라 **`conditions`(복수)**다. 단수로 쓰면 조용히 무시되고(에러 없음) 조건 없는
   전체 허용 정책이 생성되므로 최소 권한 원칙이 깨진다 — apply 후 반드시
   `terraform plan`/`aws iam get-policy-version`으로 실제 반영된 JSON을 확인한다.

이 모듈은 3개 환경이 공유하므로, monitoring에서 발견된 이 수정은 develop/production에도
다음 apply 시 동일하게 적용된다.

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

ArgoCD 차트 자신은 AWS API를 호출하지 않으므로 IRSA/Pod Identity가 불필요하다. `metrics-server`와
동일한 패턴 — `enable_argocd`만 `module "gitops_bridge_bootstrap"`(`gitops-bridge-dev/gitops-bridge/helm`,
2026-07-19 이전엔 blueprints)에 전달하고 이 모듈 자체는 별도 IAM Role을 선언하지 않는다.

이것과는 별개로 **GitOps Bridge Hub(monitoring)가 자기 자신을 spoke로 명시 등록하기 위한
IRSA**(argocd-application-controller SA가 awsAuthConfig로 K8s API를 인증하는 용도)는
root의 `gitops-bridge-irsa.tf`에 손코드로 존재한다 — "ArgoCD 차트가 AWS API를 안 부른다"와
"Hub가 자기 자신을 K8s API에 IAM으로 인증한다"는 서로 다른 문제라, 후자는 blueprints든
gitops-bridge-dev 모듈이든 대신 해주지 않는다(`temp/gitops-bridge-terraform-notes.md` 8번 참고).

### dex(SSO) 비활성화 / notifications 조건부 활성화

`values.dex.enabled = false`로 명시 비활성화한다. SSO Provider(OIDC/SAML)가 아직 구성되지
않은 상태이므로, 미구성 상태에서 활성화하면 컨테이너가 CrashLoop에 빠진다. 필요 시 이후
단계에서 SSO 구성과 함께 활성화한다.

`values.notifications.enabled`는 더 이상 고정 `false`가 아니라 `argocd_notifications_slack_enabled`
변수를 그대로 전달한다(상세: 아래 "ArgoCD Application Notifications — Slack" 절). 활성화 시
`notifications.secret.create = false`를 함께 명시하는데, argo-cd 차트의 기본값(`true`)을 그대로
두면 Helm이 `argocd-notifications-secret`을 직접 생성하려 시도해 ESO(External Secrets Operator)가
관리하는 동일 이름 Secret과 소유권이 충돌하기 때문이다.

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

### Argo Rollouts UI Extension (extensions)

`server.extensions`에 공식 [rollout-extension](https://github.com/argoproj-labs/rollout-extension)을
등록하면 argocd-server에 initContainer가 추가되어 정적 파일(`extension.tar`)을 내려받고, ArgoCD UI에서
canary/blue-green 진행 상황(step, weight 등)을 시각화한다. 신규 AWS 리소스는 생성하지 않는다.

`var.enable_argo_rollouts` 조건부로만 주입한다 — Argo Rollouts가 꺼진 환경(`enable_argo_rollouts=false`)에서
extension만 남아 있으면 표시할 Rollout 리소스가 없는데도 initContainer가 매 Pod 기동마다 불필요한
외부 다운로드를 시도하기 때문이다. `enable_argo_rollouts=true`인 환경(현재 develop/monitoring/production
전체)에서는 별도 변수 없이 자동으로 함께 켜진다.

**주의(릴리스 자산 파일명 함정)**: `EXTENSION_URL`의 파일명은 `extension.tar`다(`.tar.gz`가 아님) —
v0.4.0 기준 GitHub Releases 실제 자산명으로 확인했다. `.tar.gz`로 잘못 지정하면 초기 apply 시
initContainer가 `curl 404`로 CrashLoopBackOff에 빠지고 argocd-server 전체가 기동 실패한다
(monitoring 클러스터에서 실제로 겪은 장애 — 2026-07-09).

**버전 고정 이유(공급망 리스크)**: `EXTENSION_URL`을 `releases/latest/download/...`로 두면 GitHub의
"최신 릴리스" 별칭을 그대로 참조하게 되어 이 프로젝트의 버전 고정 원칙(위 "고정 버전" 표)을 벗어난다.
argocd-server pod는 노드 교체·HPA·크래시 등 코드 변경과 무관한 이벤트로도 자주 재시작되는데, 그때마다
initContainer가 그 시점의 최신 자산을 다시 받아온다 — 즉 git diff 없이 배포 아티팩트가 바뀔 수 있고,
업스트림 릴리스 프로세스가 침해되면 검증 없는 콘텐츠가 ArgoCD 관리자 UI(GitOps 배포 권한을 가진 특권
컨텍스트)에 그대로 반영되는 경로가 된다. 따라서 `local.rollout_extension_version`으로 특정 태그를
고정하고 `EXTENSION_VERSION`도 동일 값으로 함께 설정한다(installer 문서상 필수 필드).

`EXTENSION_CHECKSUM_URL`(다운로드 무결성 검증)은 설정하지 않았다 — rollout-extension 릴리스에
체크섬 파일 자체가 게시되지 않는다(v0.4.0 자산은 `extension.tar` 단일 파일). 검증 대상 URL이
없으므로 버전 태그 고정이 현재 확보 가능한 무결성 보장의 전부다. 업스트림이 향후 체크섬 자산을
추가하면 이 값도 함께 채운다.

### Argo Rollouts Notifications — Slack (argo_rollouts_notifications_slack_enabled)

`notifications.notifiers["service.slack"]` 하나만 opt-in 변수로 노출한다. 이 모듈은
develop/monitoring/production 3개 환경이 공유하는데, Slack Bot Token을 가리키는 Secret
(`argo-rollouts-notification-secret`, 키 `slack-token`, 네임스페이스 `argo-rollouts`)은
monitoring 계정에만 ESO(External Secrets Operator)로 준비되어 있다
(`monitoring/environments/ap-northeast-2/shared/eks-addons/argo-rollouts-notifications.tf`).
기본값을 켜두면 Secret이 없는 develop/production에도 monitoring 전용 알림 설정이 암묵적으로
새어나가 "코드만으로 의도 파악 가능" 원칙에 어긋나므로, 이 변수를 `true`로 설정하는 환경은
호출자가 해당 Secret을 직접 준비해야 한다.

`notifiers`만으로는 알림이 실제로 발송되지 않는다 — 어떤 이벤트에서 어떤 템플릿으로 보낼지는
`templates`/`triggers`/`subscriptions` 설정이 필요하며, 이 세 가지는 이 모듈(Terraform)의 관리
범위가 아니다. `eks-practice-devops-manifest` GitOps 저장소에서 Rollout 리소스에
`notifications.argoproj.io/subscriptions` annotation을 붙이는 방식으로 별도 관리한다.

값(`token: $slack-token`)의 `$slack-token`은 실제 토큰 문자열이 아니라 argo-rollouts
notifications-engine이 같은 네임스페이스의 `argo-rollouts-notification-secret` Secret에서
`slack-token` 키를 찾아 치환하는 참조 문법이다.

### ArgoCD Application Notifications — Slack (argocd_notifications_slack_enabled)

Argo Rollouts Notifications와 동일한 opt-in 패턴이지만 스키마가 근본적으로 다르다 — ArgoCD
Application은 이벤트가 아니라 상태를 계속 재평가하는 구조라 `triggers`마다 CEL 조건식인
`when`이 필수다(Argo Rollouts는 `send`만으로 충분). `templates`/`triggers`는 3종만 구성한다
(`app-health-degraded`/`app-sync-failed`/`app-sync-status-unknown`) — "정상 동작은 알림
불필요" 원칙으로 `on-deployed`/`on-sync-running`/`on-sync-succeeded`/`on-created`/`on-deleted`는
의도적으로 제외했다. `triggers`의 `when`/`oncePer`/`send`/`description`은 공식 카탈로그
(`argoproj/argo-cd` `notifications_catalog/install.yaml`)를 그대로 사용한다 — CEL 문법을
손으로 다시 옮기면 실수하기 쉽기 때문이다.

Slack Bot Token(`argocd-notifications-secret`, 키 `slack-token`, 네임스페이스 `argocd`)은
Argo Rollouts Notifications와 동일한 Slack App/Bot을 공유하므로 공용 SSM 경로
(`/eks-practice/notifications/slack-bot-token`)를 함께 참조한다. monitoring 계정에만
ESO로 준비되어 있다(`monitoring/environments/ap-northeast-2/shared/eks-addons/argocd-notifications.tf`) —
develop/production에서 이 변수를 `true`로 설정하려면 호출자가 해당 Secret을 직접 준비해야 한다.

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
