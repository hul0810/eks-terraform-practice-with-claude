################################################################################
# Karpenter NodeClaims Drainer
#
# EC2NodeClass/NodePool은 GitOps Bridge로 이관 완료 — 이제 eks-practice-devops-manifest
# 저장소의 ArgoCD Application(karpenter-resources)이 관리한다.
# Terraform은 실제 EC2 인스턴스(NodeClaim) 정리만 계속 담당한다 — 클러스터 destroy 전
# Karpenter가 아직 살아있을 때 graceful하게 노드를 회수해야 VPC CNI ENI 잔존
# (docs/environment-teardown.md 참조) 등 사고를 막을 수 있기 때문이다.
################################################################################

resource "null_resource" "karpenter_nodeclaims_drainer" {
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete nodeclaims --all --timeout=180s || true"
  }

  depends_on = [module.eks_addons]
}
