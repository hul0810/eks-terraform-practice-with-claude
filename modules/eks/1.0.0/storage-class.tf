# EKS 기본 제공 StorageClass는 gp2(레거시 in-tree provisioner kubernetes.io/aws-ebs)이며 default
# 지정도 없다 — 차트가 storageClassName을 생략하면 PVC가 전부 Pending된다. gp3는 gp2보다
# 저렴하고 성능도 높으며 EBS CSI Driver(ebs.csi.aws.com, 이 모듈이 addon으로 관리)를 사용한다.
# EBS CSI addon과 동일한 부트스트랩 레이어이므로 이 모듈이 소유하되, kubernetes provider
# 구성이 없는 root(dev/prod 클러스터 생성 이전 등)에서도 안전하도록 count로 토글한다 —
# enable_default_storage_class=false인 root는 kubernetes provider를 실제로 호출하지 않는다.
resource "kubernetes_storage_class_v1" "gp3" {
  count = var.enable_default_storage_class ? 1 : 0

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # EKS API(module.eks)와 EBS CSI addon이 모두 준비된 뒤에 생성되어야 한다 —
  # kubernetes provider의 exec 인증 자체가 module.eks 출력에 의존하지만, addon 준비 순서까지는
  # provider 의존성만으로 보장되지 않아 depends_on으로 명시한다.
  depends_on = [module.eks]
}
