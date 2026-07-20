################################################################################
# GitOps Bridge Spoke — Hub(monitoring)의 ArgoCD가 이 클러스터를 원격 관리하기 위한
# spoke Role + Access Entry + RBAC
#
# [배경 — Phase 6-5]
# monitoring 계정(157325288431)의 ArgoCD Hub가 이 클러스터(workload 계정, 657231015203)를
# spoke로 등록하려면, Hub의 IRSA Role이 이 계정의 EKS API에 접근할 권한이 필요하다.
# monitoring-self(같은 계정 안에서 직접 Access Entry)와 달리 여기는 계정이 다른
# 크로스 어카운트 상황이라, Hub Role이 이 계정 안의 spoke Role을 sts:AssumeRole로
# 넘겨받는 방식을 쓴다 — monitoring 쪽 gitops-bridge-irsa.tf가 만드는 cluster Secret의
# config.awsAuthConfig.roleARN이 아래 spoke Role의 ARN을 가리키게 된다.
#
# [3단계 체인은 monitoring-self(gitops-bridge-irsa.tf)와 동일 원리, 신뢰 주체만 다름]
#   1. aws_iam_role(spoke)              : Hub Role이 sts:AssumeRole로 이 신원을 넘겨받음
#   2. aws_eks_access_entry             : 이 spoke Role을 이 클러스터의 K8s Group에 매핑
#   3. kubernetes_cluster_role(_binding): 그 Group에 실제 K8s 권한 부여
#
# [왜 읽기 전용이 아니라 넓은 권한인가 — monitoring-self와의 차이]
# monitoring-self(Phase 6-1)는 IRSA+Access Entry+RBAC 체인이 실제로 동작하는지 검증하는
# 실습 목적이라 get/list/watch만 허용했다. 이 spoke Role은 실제 addon·워크로드 배포가
# 이 경로로 이뤄지는 진짜 운영 경로라 ArgoCD가 임의의 리소스(Deployment/Service/CRD/RBAC
# 등)를 생성·수정·삭제할 수 있어야 한다 — AWS 관리형 AmazonEKSClusterAdminPolicy 대신
# 커스텀 ClusterRole을 쓰는 이유는 gitops-bridge-irsa.tf와 동일(관리형 정책 이름에 의존하지
# 않고 이 프로젝트가 권한 범위를 직접 통제).
################################################################################

resource "aws_iam_role" "gitops_bridge_spoke" {
  name = "${local.cluster_name}-argocd-spoke-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArgocdHubAssumeSpokeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::157325288431:role/eks-practice-mon-argocd-hub-irsa"
        }
        Action = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_eks_access_entry" "argocd_spoke" {
  cluster_name      = local.cluster_name
  principal_arn     = aws_iam_role.gitops_bridge_spoke.arn
  type              = "STANDARD"
  kubernetes_groups = ["argocd-spoke-admins"]

  tags = local.common_tags
}

resource "kubernetes_cluster_role" "argocd_spoke_admin" {
  metadata {
    name = "argocd-spoke-admin"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

# subjects.name은 위 aws_eks_access_entry.argocd_spoke의 kubernetes_groups와 정확히
# 일치해야 한다(gitops-bridge-irsa.tf의 동일 패턴 참조).
resource "kubernetes_cluster_role_binding" "argocd_spoke_admin" {
  metadata {
    name = "argocd-spoke-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argocd_spoke_admin.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "argocd-spoke-admins"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [aws_eks_access_entry.argocd_spoke]
}
