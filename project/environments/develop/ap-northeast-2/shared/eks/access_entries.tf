################################################################################
# EKS 클러스터 접근 제어 (Access Entries)
#
# 콘솔/CLI로 등록 시 클러스터 재생성 후 접근 권한이 사라지는 문제를 방지한다.
# "누가 이 클러스터에 접근할 수 있는가"는 환경 종속 정책이므로 모듈이 아닌
# 환경 레벨에서 관리한다.
#
# 접근 주체 추가/제거: locals.tf의 access_entries 블록을 수정 후 terraform apply.
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
    type = "cluster"
  }
}
