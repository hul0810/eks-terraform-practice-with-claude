# EKS 애드온 설치 전략

## 실무 최소 애드온 목록

AWS 공식 문서에 "최소 애드온" 명시 기준은 없다. 아래는 이 프로젝트 기능 요구사항 기반 목록이다.

| 애드온 | 분류 | 없으면 |
|--------|------|--------|
| `vpc-cni` | Bootstrap | 노드가 클러스터 조인 자체 실패 |
| `kube-proxy` | Bootstrap | ClusterIP/NodePort 트래픽 라우팅 전면 실패 |
| `coredns` | Bootstrap | 서비스명 DNS 해석 불가, 클러스터 내 통신 장애 |
| `eks-pod-identity-agent` | Bootstrap | Pod Identity 전체 불가 → 모든 IAM 연동 실패 |
| `aws-ebs-csi-driver` | 관리형 | PVC(EBS) 생성 불가, StatefulSet 기동 실패 |
| `metrics-server` | 관리형 | `kubectl top` 불가, HPA 동작 안 함 |
| `external-dns` | 관리형 (선택) | Route53 레코드 수동 관리 필요 |
| `aws-load-balancer-controller` | Helm | Ingress/ALB Service 프로비저닝 안 됨 |
| `kube-prometheus-stack` | Helm | 클러스터·앱 가시성 없음 |
| `karpenter` | Helm (별도 모듈) | 노드 자동 프로비저닝 없어 Pending Pod 무한 대기 |

> **주의**: Karpenter와 Cluster Autoscaler(CA)는 상호 배타적. 동시 운영 시 충돌 — CA 사용 금지.

---

## 핵심 원칙

> **AWS 관리형(aws_eks_addon)으로 제공되는 것은 관리형으로 설치한다.**
> Helm(Blueprints)은 관리형이 없는 것에만 사용한다.

### 관리형 우선 이유

| 관점 | 관리형 (aws_eks_addon) | Helm (Blueprints) |
|------|----------------------|-------------------|
| EKS 업그레이드 | AWS가 호환 버전 자동 검증·추천 | Chart 버전 직접 호환성 확인 필요 |
| 보안 패치 | AWS ECR에서 즉시 배포 가능 | Helm Chart 릴리스까지 시차 발생 |
| 멀티클러스터 | AWS Console/API로 중앙 관리 | 클러스터별 Terraform 코드 관리 |
| AWS Support | 포함 | 커뮤니티 지원만 |
| Terraform 추적 | aws_eks_addon 단위로 명확 | Blueprints 내부 다수 리소스 혼합 |

---

## 애드온 분류

### AWS 관리형 애드온 (aws_eks_addon)

AWS가 버전 호환성을 검증하고 ECR에 이미지를 호스팅하는 공식 애드온.

#### Bootstrap 애드온 — `modules/eks`에서 관리

클러스터 생성 시 노드 조인에 필요한 애드온. 클러스터 lifecycle과 묶여 있으므로
`modules/eks/1.0.0/main.tf`의 `addons` 블록에서 관리한다.

| 애드온 | EKS 이름 | 비고 |
|--------|----------|------|
| Amazon VPC CNI | `vpc-cni` | `before_compute = true` (노드보다 먼저 배포) |
| kube-proxy | `kube-proxy` | |
| CoreDNS | `coredns` | |

#### 애플리케이션 레벨 관리형 — `modules/eks-addons`에서 관리

클러스터 구축 후 독립적으로 설치·운영. `modules/eks-addons/1.0.0/main.tf`의
`aws_eks_addon` 리소스로 직접 선언한다.

| 애드온 | EKS 이름 | IAM 필요 | 비고 |
|--------|----------|----------|------|
| EKS Pod Identity Agent | `eks-pod-identity-agent` | 없음 | 다른 애드온보다 먼저 설치 (depends_on) |
| Amazon EBS CSI Driver | `aws-ebs-csi-driver` | AmazonEBSCSIDriverPolicy | |
| Kubernetes Metrics Server | `metrics-server` | 없음 | Community 관리형 (2025.03~) |
| External DNS | `external-dns` | Route53 권한 | Community 관리형 (2025.03~) |

### Helm 전용 애드온 — `modules/eks-addons`에서 관리

AWS 관리형이 존재하지 않아 Helm Chart로만 설치 가능한 애드온.
`aws-ia/eks-blueprints-addons` 모듈의 `helm_release` 래핑을 활용한다.

| 애드온 | Helm Chart | IAM 필요 | 비고 |
|--------|------------|----------|------|
| AWS Load Balancer Controller | `eks-charts/aws-load-balancer-controller` | AWSLoadBalancerControllerIAMPolicy | |
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | 없음 | Prometheus + Grafana + AlertManager 통합 |

### Karpenter — `modules/karpenter`에서 별도 관리

오토스케일러는 클러스터 구축 직후 설치되며 IAM Role + SQS + EventBridge를 함께
구성해야 하므로 독립 모듈로 분리한다.

| 애드온 | 설치 방식 | 비고 |
|--------|-----------|------|
| Karpenter | `aws-ia/eks-blueprints-addons` (`enable_karpenter = true`) | IAM Role + SQS 인터럽션 큐 + EventBridge Rule 자동 |

---

## IAM / Pod Identity 연동 패턴

이 프로젝트의 기본 IAM 전략은 **Pod Identity**다. OIDC Provider(IRSA)는 서드파티 도구 호환성을
위해 활성화 상태로 유지하지만, 신규 애드온 연동 시에는 Pod Identity를 우선 사용한다.

```hcl
# IAM Role 생성
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Pod Identity 연결
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
```

> `aws_eks_pod_identity_association`은 `eks-pod-identity-agent` 애드온이 설치된 후에
> 동작한다. `depends_on`으로 순서를 보장한다.

---

## 버전 관리

### EKS 관리형 애드온 버전 고정

`most_recent = true` 사용 금지. `addon_version`을 반드시 명시한다.

```hcl
resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = var.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = "v1.x.x-eksbuild.x"  # 명시 고정 필수
}
```

버전 조회:
```bash
aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name aws-ebs-csi-driver \
  --region ap-northeast-2 \
  --query 'addons[].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion' \
  --output text
```

### Helm Chart 버전 고정

`version`을 명시하고, `repository`를 고정한다. `latest` 또는 버전 미지정 금지.

---

## 업그레이드 절차

### EKS 관리형 애드온

1. 신규 버전 조회: `aws eks describe-addon-versions --kubernetes-version <k8s-ver> --addon-name <name>`
2. `defaultVersion: true` 버전 확인
3. `addon_version` 값 수정
4. `terraform plan` 검토 → `terraform apply`

### Helm 애드온

1. `helm repo update`
2. `helm search repo <chart-name> --versions` 로 최신 버전 확인
3. `modules/eks-addons/1.0.0/main.tf`의 `chart_version` 수정
4. `terraform plan` 검토 → `terraform apply`
