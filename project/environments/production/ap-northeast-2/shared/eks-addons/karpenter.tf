################################################################################
# Karpenter NodeClaim 정리 — EC2NodeClass/NodePool은 이제 여기 없다
#
# devops-manifest의 karpenter-resources Application이 EC2NodeClass "default"와
# NodePool 4종(general/arm64/gpu/spot) 전부를 server-side-apply로 관리한다(dev와 동일
# 패턴 — annotation karpenter_consolidate_after는 이 root의 gitops-bridge-registry.tf가
# publish하는 locals.tf의 gitops_bridge_registry_payload.karpenter_nodepool_metadata 참조).
# production이 프로비저닝되어 spoke로 등록되면 같은 karpenter-resources 차트가 4종
# 전부를 가져가므로, 이 root도 처음부터 그 최종 상태를 반영해뒀다 — 실제 라이브
# state가 생긴 뒤에 별도 이관 작업이 필요 없다. 결과적으로 Karpenter의 Kubernetes
# 리소스(EC2NodeClass/NodePool)는 전부 ArgoCD 소관이고, 이 root에는 AWS 리소스
# (IRSA Role/Policy, 노드 IAM Role, SQS, EventBridge — main.tf의 module.eks_addons)만
# 남는다.
################################################################################

# ── Karpenter NodeClaim 정리 (destroy 시 EC2 인스턴스 고아 방지) ──────────────
#
# 문제: NodePool에는 "karpenter.sh/termination" finalizer가 있다.
# Karpenter 컨트롤러가 그 NodePool로 생성된 NodeClaim(EC2 인스턴스)을 모두
# drain·terminate해야만 finalizer가 제거되고 NodePool 오브젝트가 삭제된다.
# NodePool 자체는 이제 ArgoCD 소관이라 Terraform destroy 대상이 아니지만, 이 root가
# destroy될 때(module.eks_addons의 Karpenter IRSA Role 등 AWS 리소스 삭제) Karpenter
# 컨트롤러가 AWS API 인증을 잃기 전에 NodeClaim(EC2 인스턴스)을 먼저 정리해야
# 고아 인스턴스가 남지 않는다.
#
# 해결: module.eks_addons보다 먼저 destroy되는 null_resource에서
# `kubectl delete nodeclaims --all`을 실행해, Karpenter 컨트롤러가 아직
# 살아있는 시점에 모든 NodeClaim 정리를 명시적으로 트리거한다.
# timeout + `|| true`로 최악의 경우에도 destroy 자체는 멈추지 않도록 한다.
#
# destroy 순서:
#   1. null_resource destroy → kubectl delete nodeclaims --all (EC2 인스턴스 정리)
#   2. module.eks_addons destroy → IRSA Role, SQS, Helm chart 등 AWS 리소스 삭제
resource "null_resource" "karpenter_nodeclaims_drainer" {
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete nodeclaims --all --timeout=180s || true"
  }

  depends_on = [
    # module.eks_addons가 아직 살아있는 상태에서 drain을 트리거해야 한다.
    # 미포함 시 Terraform이 병렬로 삭제하여 Karpenter 컨트롤러가 먼저 사라질 수 있다.
    module.eks_addons,
  ]
}
