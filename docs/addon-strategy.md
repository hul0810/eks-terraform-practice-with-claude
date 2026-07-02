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
| `argocd` | Helm (blueprints) | GitOps 동기화 불가 (Phase 5 이후 필수) |
| `argo-rollouts` | Helm (blueprints) | Canary·Blue-Green 배포 불가, Rollout 리소스 처리 안 됨 |
| `external-secrets` | Helm (blueprints) | AWS SSM Parameter Store/Secrets Manager 값을 K8s Secret으로 동기화 불가, 시크릿 수동 관리 필요 |

> **주의**: Karpenter와 Cluster Autoscaler(CA)는 상호 배타적. 동시 운영 시 충돌 — CA 사용 금지.

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
| ArgoCD | Helm (Blueprints) | GitOps 전환(Phase 5) 시작점. AWS API 미호출로 IAM 불필요 |
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

`aws-ia/eks-blueprints-addons` 모듈로 관리한다. blueprints가 IRSA IAM Role 생성과
Helm values `serviceAccount.annotations` 주입을 내부에서 자동 처리한다.

| 애드온 | IAM | 비고 |
|--------|-----|------|
| AWS Load Balancer Controller | IRSA (blueprints 자동 처리) | |
| ExternalDNS | IRSA (blueprints 자동 처리) | `enable_external_dns = false`로 비활성화 가능 |
| Metrics Server | 없음 | |
| Karpenter | IRSA (blueprints 자동 처리) | `enable_karpenter = false`로 비활성화 가능 |
| ArgoCD | 없음 | GitOps 전환(Phase 5) 시작점. AWS API 미호출로 IAM 불필요 |
| Argo Rollouts | 없음 | Canary·Blue-Green 배포 전략 구현. AWS API 미호출로 IAM 불필요 |
| External Secrets Operator | IRSA(blueprints 자동 처리, 이번 단계에서는 스코프 미지정) | `enable_external_secrets = false`로 비활성화 가능. ArgoCD repo-creds용 ClusterSecretStore/ExternalSecret은 `monitoring/environments/ap-northeast-2/shared/eks-addons/main.tf`에서 구성 완료 |

### Secrets Store CSI Driver 대신 External Secrets Operator를 쓰는 이유 (2026-07-02 결정)

이 프로젝트는 Secrets Store CSI Driver + ASCP를 사용하지 않는다. 두 방식을 비교한 결과:

- **Secrets Store CSI Driver**: 대상 Pod의 볼륨에 시크릿을 파일로 마운트하는 방식. 앱이 파일시스템에서 값을 읽어야 하고, 자동 갱신(polling)이 있어도 K8s Secret 오브젝트로 변환하려면 `syncSecret` 기능을 별도로 켜야 한다.
- **External Secrets Operator**: SSM Parameter Store/Secrets Manager 값을 K8s Secret으로 직접 동기화한다. ArgoCD repo-creds처럼 K8s Secret 형태 자체가 필요한 대상(Helm values, 컨트롤러가 기대하는 Secret 라벨 규칙 등)에 바로 맞고, `refreshInterval`로 갱신 주기를 세밀하게 제어할 수 있다.

이 프로젝트가 다루는 민감 정보(ArgoCD admin 패스워드, GitHub App 인증 정보 등)는 전부 K8s Secret 형태로 소비되므로 ESO가 목적에 더 부합한다. 두 도구를 동시에 운영하면 시크릿 접근 경로가 두 갈래로 나뉘어 운영 복잡도만 늘어나므로, ESO 하나로 통일한다.

> ArgoCD repo-creds(`ClusterSecretStore/aws-parameterstore`, `ExternalSecret/argocd-github-app-repo-creds`)가
> Terraform 소관인 이유는 애드온별 사유가 아니라 아래 "GitOps 관리 경계" 원칙에 따른 것이다.

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
| ArgoCD repo-creds (ClusterSecretStore/ExternalSecret 등 ArgoCD의 Git 인증정보) | 불가 → Terraform | ArgoCD가 devops-manifest 저장소 인증정보를 그 저장소 안에서 가져올 수 없음 |
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

blueprints 모듈에 `oidc_provider_arn`을 전달하면 IAM Role 생성과
Helm values `serviceAccount.annotations` 주입을 내부에서 자동 처리한다.
blueprints가 IRSA를 강제하므로 이 경우에만 IRSA를 사용한다.

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
