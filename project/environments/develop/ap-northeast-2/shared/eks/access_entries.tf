################################################################################
# EKS 클러스터 접근 제어 (Access Entries)
#
# EKS API 기반 접근 제어. IAM 엔티티(User/Role)에 Kubernetes 권한을 부여한다.
# AWS IAM 권한(EKS 생성/수정)과 Kubernetes 권한(kubectl)은 별도 레이어로 분리된다.
# → 인프라를 생성하는 권한과 클러스터에 접근하는 권한이 다르다.
#
# 접근 주체 관리: locals.tf의 access_entries 블록
#   - principal_arn: 접근을 허용할 IAM User 또는 Role ARN
#   - policy_arn: 부여할 Kubernetes 권한 수준
#       · AmazonEKSClusterAdminPolicy : 클러스터 전체 관리자
#       · AmazonEKSEditPolicy         : 네임스페이스 수준 편집
#       · AmazonEKSViewPolicy         : 읽기 전용
#   - access_scope.type: "cluster"(전체) 또는 "namespace"(특정 네임스페이스)
#
# 클러스터를 재생성해도 Terraform apply 한 번으로 접근 권한이 자동 복원된다.
################################################################################

resource "aws_eks_access_entry" "this" {
  for_each = local.access_entries

  cluster_name  = module.eks.cluster_name
  principal_arn = each.value.principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access_entries

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = try(each.value.access_scope.namespaces, null)
  }
}
