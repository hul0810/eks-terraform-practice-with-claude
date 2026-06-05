# modules/eks-addons 설계 원칙

## 이 모듈이 관리하는 애드온 (5종)

| 애드온 | 설치 방법 | IAM 방식 |
|--------|-----------|---------|
| aws-ebs-csi-driver | EKS 관리형 addon | Pod Identity |
| metrics-server | EKS 관리형 addon | 없음 (불필요) |
| external-dns | EKS 관리형 addon (조건부) | Pod Identity |
| aws-load-balancer-controller | Helm (eks-blueprints-addons) | IRSA |
| kube-prometheus-stack | Helm (eks-blueprints-addons) | 없음 |

---

## 고정 버전 (EKS 1.33 / ap-northeast-2 / 2026-06-05 조회)

| 구분 | 이름 | 고정 버전 |
|------|------|-----------|
| EKS 관리형 addon | aws-ebs-csi-driver | `v1.60.1-eksbuild.1` |
| EKS 관리형 addon | metrics-server | `v0.8.1-eksbuild.10` |
| EKS 관리형 addon | external-dns | `v0.21.0-eksbuild.4` |
| Terraform 모듈 | aws-ia/eks-blueprints-addons | `~> 1.23.0` |
| Helm chart | aws-load-balancer-controller | `3.4.0` |
| Helm chart | kube-prometheus-stack | `86.1.1` |

---

## eks-pod-identity-agent 중복 선언 금지

`eks-pod-identity-agent`는 `modules/eks`의 `addons` 블록에서 bootstrap 단계에 설치된다.
이 모듈에서 중복 선언하면 `aws_eks_addon` 리소스 충돌로 `apply`가 실패한다.

모든 Pod Identity(`aws_eks_pod_identity_association`) 연동은 agent가 이미 실행 중임을 전제로 한다.

---

## LBC IAM: IRSA 사용 이유

LBC는 EKS 관리형 addon이 없는 Helm-only 컴포넌트다.
`eks-blueprints-addons` 모듈이 내부적으로 IRSA 방식으로 IAM Role을 생성하고
Helm values에 `serviceAccount.annotations`를 자동 주입한다.

Pod Identity로 전환하려면 `eks-blueprints-addons`의 내부 구현을 대체해야 한다.
모듈 외부에서 IAM Role을 별도로 만들고 `set`으로 주입하는 방식은 관리 이중화를 초래하므로
현재 버전(1.23.0)에서는 Blueprints의 IRSA 구현을 그대로 사용한다.

`modules/eks`에서 `enable_irsa = true`로 OIDC Provider를 유지하는 이유 중 하나가 이것이다.

---

## kube-prometheus-stack: Pending 정상 시나리오

kube-prometheus-stack Pod에는 `CriticalAddonsOnly` toleration이 없다.
Karpenter NodePool 구성 완료(Karpenter 설치 → NodeClass → NodePool 순서) 이전에는
앱 워크로드를 수용할 노드가 없어 Pod가 Pending 상태가 된다.

이는 의도된 동작이다. Karpenter가 NodePool을 인식하면 자동으로 노드를 프로비저닝하고
Pod가 Running 상태로 전환된다.

---

## External DNS 조건부 설치 패턴

공식 모듈 표준(`aws-ia/eks-blueprints-addons` 등)에 따라 단순 on/off 토글은 `count = bool ? 1 : 0`을 사용한다.
이 리소스들은 독립적으로 0개 또는 1개만 존재하고 순서 의존성이 없어 재인덱싱 문제가 발생하지 않는다.

```hcl
count = var.enable_external_dns ? 1 : 0
```

리소스 주소: `aws_iam_role.external_dns[0]`
출력에서 꺼낼 때: `var.enable_external_dns ? aws_iam_role.external_dns[0].arn : null`

**count vs for_each 선택 기준** (`docs/terraform-principles.md` 참조):
- `count = bool ? 1 : 0`: 단일 on/off, 순서 무관한 경우 (공식 모듈 표준)
- `for_each`: 여러 개를 반복하거나 순서 영향이 있는 경우 (SG ingress rule 등)

---

## 버전 업그레이드 절차

### EKS 관리형 addon

```bash
aws eks describe-addon-versions \
  --kubernetes-version <k8s-ver> \
  --addon-name <addon-name> \
  --region ap-northeast-2
```

`defaultVersion: true` 버전 확인 후 `variables.tf`의 `addon_versions` 기본값 및
`environments/.../eks-addons/locals.tf`의 값을 수동 변경한다.

### Helm chart

Artifact Hub 또는 GitHub Releases에서 최신 stable 버전 확인:
- LBC: https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases
- kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/releases

`environments/.../eks-addons/locals.tf`의 `lbc_chart_version` / `kube_prometheus_stack_chart_version`
값을 수동 변경한다.
