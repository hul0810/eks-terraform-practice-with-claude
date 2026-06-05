################################################################################
# EKS Addons 모듈 — Pod Identity 전략
#
# 관리 범위: EBS CSI Driver, Metrics Server, External DNS, AWS Load Balancer Controller
#
# 이 모듈은 클러스터 bootstrap 이후 설치하는 애플리케이션 레벨 애드온을 관리한다.
# eks-pod-identity-agent는 modules/eks에서 bootstrap 단계에 설치되므로 여기서 선언하지 않는다.
#
# [IAM 전략 선택: Pod Identity vs IRSA]
#
# EKS 관리형 애드온(aws_eks_addon)은 aws_eks_pod_identity_association으로 IAM을 연결한다.
# aws-ia/eks-blueprints-addons 모듈을 사용하지 않는 이유:
#   1. blueprints 모듈은 IRSA 전용 설계다. Pod Identity 지원 계획이 공식적으로 없다.
#      (github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/289 — Closed as Not Planned)
#   2. IRSA는 OIDC trust policy에 namespace/serviceaccount 조건을 직접 작성해야 하고,
#      Pod Identity는 trust principal이 pods.eks.amazonaws.com으로 단순하다.
#   3. AWS는 Pod Identity를 신규 워크로드의 권장 방식으로 명시하고 있다.
#      (docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
#
# 예외: AWS Load Balancer Controller는 EKS 관리형 addon이 없어 Helm 설치가 유일하다.
#       blueprints 모듈이 Helm + IRSA를 통합 처리하므로 해당 섹션만 blueprints를 사용한다.
#
# 비교 구현 1 — Pod Identity 전용(blueprints 없음): modules/eks-addons-pod-identity/1.0.0/
################################################################################


################################################################################
# 섹션 1: EBS CSI Driver — aws_eks_addon + Pod Identity
#
# blueprints 미사용 이유: EBS CSI Driver는 EKS 관리형 addon이다. blueprints 모듈은
# EKS 관리형 addon을 지원하지 않으며(Helm chart 방식), IAM도 IRSA로만 처리한다.
# aws_eks_addon + aws_eks_pod_identity_association 조합이 관리형 + Pod Identity 모두를
# 충족하는 유일한 방법이다.
#
# eks-pod-identity-agent가 modules/eks에서 사전 설치되어 있어야 정상 동작한다.
################################################################################

resource "aws_iam_role" "ebs_csi" {
  name        = "${var.cluster_name}-ebs-csi-driver"
  description = "EBS CSI Driver Pod Identity IAM Role - ${var.cluster_name}"

  # Pod Identity trust policy: pods.eks.amazonaws.com이 assume하도록 허용
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
      }
    ]
  })

  tags = var.additional_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_versions.ebs_csi_driver
  resolve_conflicts_on_update = "OVERWRITE"

  # Pod Identity Association이 먼저 존재해야 addon이 IAM을 정상 인식한다
  depends_on = [aws_eks_pod_identity_association.ebs_csi]
}


################################################################################
# 섹션 2: Metrics Server — aws_eks_addon (IAM 불필요)
#
# blueprints 미사용 이유: blueprints는 metrics-server를 Helm chart로 설치한다.
# EKS 관리형 addon(aws_eks_addon)을 사용하면 AWS가 버전 관리·보안 패치를 담당하므로
# 관리형 addon이 존재하는 경우 항상 이를 우선한다 (docs/addon-strategy.md 참조).
# IAM 권한이 없으므로 Pod Identity/IRSA 모두 불필요하다.
################################################################################

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = var.cluster_name
  addon_name                  = "metrics-server"
  addon_version               = var.addon_versions.metrics_server
  resolve_conflicts_on_update = "OVERWRITE"
}


################################################################################
# 섹션 3: External DNS — aws_eks_addon + Pod Identity (조건부 설치)
#
# blueprints 미사용 이유: EBS CSI와 동일. EKS 관리형 addon + Pod Identity 조합.
# blueprints의 enable_external_dns는 Helm chart + IRSA로 동작하며, 관리형 addon을
# 사용할 수 없고 IAM도 IRSA trust policy로 복잡하게 작성해야 한다.
#
# count 사용 근거: 단일 on/off 토글이므로 공식 모듈 표준(count = bool ? 1 : 0)을 따른다.
# 이 리소스들은 독립적으로 하나만 존재하며 순서 의존성이 없어 count 재인덱싱 문제가 없다.
################################################################################

resource "aws_iam_role" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name        = "${var.cluster_name}-external-dns"
  description = "External DNS Pod Identity IAM Role - ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
      }
    ]
  })

  tags = var.additional_tags
}

resource "aws_iam_policy" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name        = "${var.cluster_name}-external-dns"
  description = "Minimum permissions for External DNS to manage Route53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = var.additional_tags
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  role       = aws_iam_role.external_dns[0].name
  policy_arn = aws_iam_policy.external_dns[0].arn
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn
}

resource "aws_eks_addon" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  cluster_name                = var.cluster_name
  addon_name                  = "external-dns"
  addon_version               = var.addon_versions.external_dns
  resolve_conflicts_on_update = "OVERWRITE"

  # Pod Identity Association이 먼저 존재해야 addon이 IAM을 정상 인식한다
  depends_on = [aws_eks_pod_identity_association.external_dns]
}


################################################################################
# 섹션 4: Helm 전용 애드온 — blueprints 사용 (IRSA, 예외 케이스)
#
# AWS Load Balancer Controller는 EKS 관리형 addon이 존재하지 않아 Helm 설치가 유일하다.
# blueprints 모듈이 Helm chart + IRSA IAM Role을 통합 처리하므로 이 경우에만 예외적으로
# blueprints를 사용한다. IRSA가 필요하므로 oidc_provider_arn을 반드시 전달해야 한다.
#
# blueprints가 IRSA 전용인 이유:
#   - 모듈 설계 당시(2022~2023) Pod Identity가 없었음 (Pod Identity 출시: 2023년 11월)
#   - Pod Identity 전환 요청(issue #289)이 "Not Planned"으로 종료됨
#   - 따라서 LBC는 이 모듈에서 유일한 IRSA 사용 애드온이다
# LBC를 Pod Identity로만 구현한 비교 모듈: modules/eks-addons-pod-identity/1.0.0/
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.23.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    chart_version = var.lbc_chart_version
    set = [
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key", value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect", value = "NoSchedule" },
    ]
  }

  tags = var.additional_tags
}
