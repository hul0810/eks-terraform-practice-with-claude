locals {
  environment = "monitoring"
  project     = "eks-practice"

  environment_short = "mon"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_arn  = data.aws_eks_cluster.this.arn
  account_id   = data.aws_caller_identity.current.account_id
  namespace    = "monitoring"

  # LGTM 스택(Loki/Mimir/Tempo) 오브젝트 스토리지 백엔드 3종 — 각각 전용 S3 버킷 + Pod Identity
  # Role을 갖는다(버킷별 분리는 iam.tf 참조). service_account는 Helm 차트가 monitoring
  # 네임스페이스에 생성하는 이름과 일치해야 pod-identity.tf의 Association이 매칭된다.
  backends = {
    loki = {
      bucket_name     = "eks-practice-mon-loki-${local.account_id}"
      service_account = "loki"
    }
    mimir = {
      bucket_name     = "eks-practice-mon-mimir-${local.account_id}"
      service_account = "mimir"
    }
    tempo = {
      bucket_name     = "eks-practice-mon-tempo-${local.account_id}"
      service_account = "tempo"
    }
  }

  # Pod Identity 세션 태그(aws:PrincipalTag) 기반 ABAC 조건 — iam.tf의 S3 권한 정책이 참조한다.
  # 이 Role이 "의도한 클러스터의 monitoring 네임스페이스, 지정된 SA"로 assume된 경우에만 S3 권한이
  # 유효하다. eks-cluster-arn을 반드시 포함한다 — namespace+service_account는 클러스터 간 유일하지
  # 않아(다른 클러스터에 동일 이름이 존재할 수 있음) cluster-arn 없이는 격리가 불완전하다
  # (AWS EKS Best Practices 확인분). 효과: CreatePodIdentityAssociation 권한을 가진 주체가 이 Role을
  # 다른 파드/네임스페이스에 붙여도 S3 접근이 거부된다(버킷별 격리 의도를 IAM 레벨에서 강제).
  pod_identity_abac_condition = {
    for k, v in local.backends : k => {
      StringEquals = {
        "aws:PrincipalTag/kubernetes-namespace"       = local.namespace
        "aws:PrincipalTag/kubernetes-service-account" = v.service_account
        "aws:PrincipalTag/eks-cluster-arn"            = local.cluster_arn
      }
    }
  }
}
