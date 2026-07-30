# 서비스어카운트(loki/mimir/tempo)는 Helm 차트가 monitoring 네임스페이스에 직접 생성한다 —
# Terraform은 SA를 만들지 않는다. Association은 SA 존재 여부와 무관하게 미리 생성해도 무방하다
# (Pod Identity는 SA에 어노테이션을 요구하지 않고, EKS가 cluster_name+namespace+service_account
# 조합만으로 매칭한다).
#
# serviceAccount에 eks.amazonaws.com/role-arn(IRSA) 어노테이션은 절대 붙이지 않는다 — Pod
# Identity와 IRSA를 동일 SA에 병용하면 IRSA가 우선 적용되어 이 Association이 무시된다.
resource "aws_eks_pod_identity_association" "this" {
  for_each = local.backends

  cluster_name    = local.cluster_name
  namespace       = local.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.this[each.key].arn

  tags = local.common_tags
}
