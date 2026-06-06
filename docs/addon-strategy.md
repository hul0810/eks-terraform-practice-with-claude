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
| `aws-load-balancer-controller` | Helm | Ingress/ALB Service 프로비저닝 안 됨 |
| `external-dns` | Helm (선택) | Route53 레코드 수동 관리 필요 |
| `metrics-server` | Helm | `kubectl top` 불가, HPA 동작 안 함 |
| `karpenter` | Helm | 노드 자동 프로비저닝 없어 Pending Pod 무한 대기 |

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
| CoreDNS | Bootstrap (`aws_eks_addon`) | AWS 관리형, 클러스터 DNS 핵심 |
| EKS Pod Identity Agent | Bootstrap (`aws_eks_addon`) | AWS 관리형, Karpenter 등 Pod Identity 의존 컴포넌트 전제 조건 |
| EBS CSI Driver | Bootstrap (`aws_eks_addon`) | AWS 관리형, 클러스터 초기화 시 필요 |
| AWS LB Controller | Helm (Blueprints) | EKS 관리형 없음, Helm values 커스터마이징 필요 |
| ExternalDNS | Helm (Blueprints) | Route53 zone 등 Helm values 커스터마이징 필요 |
| Metrics Server | Helm (Blueprints) | Helm values 커스터마이징 필요 |
| Karpenter | Helm (Blueprints) | EKS 관리형 없음, EC2NodeClass·NodePool 등 values 커스터마이징 필수 |

---

## 애드온 분류

### Bootstrap 애드온 — `modules/eks`에서 관리

클러스터 초기화 시 함께 배포되는 애드온. 클러스터 lifecycle과 묶여 있으므로
`modules/eks/1.0.0/main.tf`에서 관리한다.

| 애드온 | EKS 이름 | IAM | 비고 |
|--------|----------|-----|------|
| Amazon VPC CNI | `vpc-cni` | Pod Identity | 노드 그룹이 `depends_on = [module.eks]`로 모든 애드온 ACTIVE 후 생성됨 |
| kube-proxy | `kube-proxy` | 없음 | |
| CoreDNS | `coredns` | 없음 | |
| EKS Pod Identity Agent | `eks-pod-identity-agent` | 없음 | Karpenter보다 먼저 설치 |
| Amazon EBS CSI Driver | `aws-ebs-csi-driver` | Pod Identity | IAM Role은 module.eks 호출 전에 생성. `addons` 블록 내 `pod_identity_association`으로 연결 |

> **순서 보장**: Pod Identity는 OIDC Provider ARN이 불필요하므로 `aws_iam_role.ebs_csi`를
> `module.eks` 호출 전에 선언해도 순환 의존성이 발생하지 않는다.
> IAM Role ARN은 `addons.aws-ebs-csi-driver.pod_identity_association`으로 전달한다.

### Helm 전용 애드온 — `modules/eks-addons`에서 관리

`aws-ia/eks-blueprints-addons` 모듈로 관리한다. blueprints가 IRSA IAM Role 생성과
Helm values `serviceAccount.annotations` 주입을 내부에서 자동 처리한다.

| 애드온 | IAM | 비고 |
|--------|-----|------|
| AWS Load Balancer Controller | IRSA (blueprints 자동 처리) | |
| ExternalDNS | IRSA (blueprints 자동 처리) | `enable_external_dns = false`로 비활성화 가능 |
| Metrics Server | 없음 | |
| Karpenter | IRSA (blueprints 자동 처리) | `enable_karpenter = false`로 비활성화 가능 |

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
