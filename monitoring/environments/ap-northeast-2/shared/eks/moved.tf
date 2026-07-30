# gp3 기본 StorageClass가 이 root의 개별 리소스에서 modules/eks/1.0.0(enable_default_storage_class)로
# 이전되었다. 이미 apply되어 클러스터에 살아있는 리소스이므로 moved 블록 없이 재선언하면
# 삭제 후 재생성이 발생한다 — moved 블록으로 state만 이전하고 실제 리소스는 그대로 둔다.
moved {
  from = kubernetes_storage_class_v1.gp3
  to   = module.eks.kubernetes_storage_class_v1.gp3[0]
}
