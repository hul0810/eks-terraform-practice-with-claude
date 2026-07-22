################################################################################
# GitOps Bridge Spoke — Hub(monitoring)의 ArgoCD가 이 클러스터를 원격 관리하기 위한
# spoke Role + Access Entry + 관리형 Access Policy
#
# monitoring 계정(157325288431)의 ArgoCD Hub가 이 클러스터(workload 계정, 657231015203)를
# spoke로 등록하려면, Hub의 IRSA Role이 이 계정의 EKS API에 접근할 권한이 필요하다. 크로스
# 어카운트라 Hub Role을 이 클러스터의 access entry principal로 직접 등록하는 대신, 이 계정이
# 소유하는 별도 spoke Role을 만들어 Hub Role은 그 Role만 sts:AssumeRole로 넘겨받게 한다 —
# "누가 이 Role을 assume할 수 있는가"(신뢰)와 "그 Role이 뭘 할 수 있는가"(권한) 양쪽 다 이
# 계정이 소유·통제해서, Hub 계정 쪽 IAM이 나중에 바뀌어도(예: 그 Role의 신뢰 정책이 다른
# 신원까지 허용하도록 확장되어도) 그 변경이 이 클러스터의 접근 범위로 자동으로 새어들지
# 않는다. monitoring 쪽 gitops-bridge-irsa.tf가 만드는 cluster Secret의
# config.awsAuthConfig.roleARN이 아래 spoke Role의 ARN을 가리킨다.
#
# [2단계 체인]
#   1. aws_iam_role(spoke)                                    : Hub Role만 sts:AssumeRole로
#      이 신원을 넘겨받을 수 있음
#   2. aws_eks_access_entry + aws_eks_access_policy_association: 이 신원에
#      AmazonEKSClusterAdminPolicy를 클러스터 범위로 부여
#
# [왜 커스텀 ClusterRole이 아니라 관리형 정책인가]
# ArgoCD가 실제 addon·워크로드 배포를 위해 임의의 리소스(Deployment/Service/CRD/RBAC 등)를
# 생성·수정·삭제해야 하는 진짜 운영 경로라, 필요한 권한 범위 자체가 cluster-admin과
# 동급이다 — monitoring-self(gitops-bridge-irsa.tf, get/list/watch만 필요)처럼 관리형 정책
# 3티어(View/AdminView/ClusterAdmin) 중 어느 것도 딱 안 맞는 경우와 달리, 여기는 원하는
# 권한 범위가 AmazonEKSClusterAdminPolicy와 정확히 일치해 커스텀 ClusterRole+
# ClusterRoleBinding을 직접 유지보수할 이유가 없다.
#
# [production apply 보류] CLAUDE.md "Production 배포 정책"에 따라 이 파일의 apply는
# 사용자가 직접 실행한다(`.claude/hooks/block-production-apply.sh`가 어차피 차단) — 코드는
# develop과 완전히 동일한 구조다(계정/클러스터 이름만 다름).
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
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.gitops_bridge_spoke.arn
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "argocd_spoke_admin" {
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.gitops_bridge_spoke.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
