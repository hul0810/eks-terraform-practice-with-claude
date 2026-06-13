locals {
  environment = "production"
  project     = "eks-practice"

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # eks/ state에서 참조하는 클러스터 정보
  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.eks.outputs.cluster_endpoint
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  # aws_eks_cluster data source로 VPC ID 조회 — remote_state에 vpc_id output이 없어 data source 활용
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # eks/locals.tf의 kubernetes_version과 동기화 — EKS 버전 업그레이드 시 함께 변경한다
  cluster_version = "1.33"

  # production: replica_counts={} → 모듈 기본값 사용 (lbc=2, karpenter=2, external_dns=1, metrics_server=1)
  # 시스템 노드 HA 여부는 eks/locals.tf의 system_node 설정을 참조 (현재 min=desired=1, 비용 예외)
  replica_counts = {}

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전
    # 버전 업그레이드: helm repo update && helm search repo <chart> --versions
    lbc_chart_version            = "3.4.0"
    external_dns_chart_version   = "1.14.5"
    metrics_server_chart_version = "3.12.2"
    karpenter_chart_version      = "1.12.1"
    argocd_chart_version         = "9.5.21"

    enable_aws_load_balancer_controller = true
    # 운영 도메인/Route53 Hosted Zone 미구성으로 비활성화.
    # 도메인 준비 후 enable_external_dns = true로 변경하고
    # external_dns_route53_zone_arns에 해당 zone ARN을 명시할 것 (production은 zone ARN 필수).
    enable_external_dns            = false
    external_dns_route53_zone_arns = []
    enable_metrics_server          = true
    enable_karpenter               = true
    enable_argocd                  = true
    # 시스템 노드 min/desired=1(비용 예외, eks/locals.tf 참조)인 상태에서 HA를 켜면
    # redis-ha quorum이 spot 노드에 분산되어 단일 노드 장애 시 ArgoCD 전체가 다운될 수 있다.
    # 시스템 노드 HA 복원(min/desired=2) 시 true로 함께 전환할 것 (redis-ha + replica=2).
    argocd_ha_enabled = false
  }

  # ── Karpenter NodePool 정의 ──────────────────────────────────────────────────
  # 분리 기준: 인스턴스 요건이 아니라 워크로드 격리 요건
  #   - 아키텍처(amd64/arm64): 이미지 호환성 보장을 위해 분리
  #   - GPU: Taint로 일반 Pod 차단 필수 → 별도 NodePool
  #   - Spot-only: 중단 감수 워크로드를 Taint로 강제 격리
  #   - CPU/메모리 집약: 분리 불필요. Pod의 resources.requests를 보고 Karpenter가 자동 선택
  #
  # weight: 동일 Pod가 여러 NodePool에 스케줄 가능할 때 우선순위 (높을수록 우선)
  # taints: 빈 리스트면 Taint 없음 (일반 Pod도 스케줄 가능)
  karpenter_node_pools = {
    # 범용 워크로드 — amd64 기본 진입점
    # spot+on-demand 혼합 허용: 일반 워크로드는 비용 절감을 위해 spot도 허용한다.
    # spot 중단에 취약한 워크로드(Stateful, 긴 배치 작업 등)는 PDB 또는
    # nodeSelector/affinity로 on-demand를 명시적으로 요청해야 한다.
    general = {
      capacity_types    = ["spot", "on-demand"]
      instance_families = ["c", "m", "r"]
      architectures     = ["amd64"]
      instance_gen_min  = "2"
      weight            = 10
      taints            = []
      limits            = { cpu = "100", memory = "400Gi" }
    }

    # Graviton 워크로드 — arm64 이미지를 사용하는 워크로드 전용
    # Pod에서 nodeSelector: kubernetes.io/arch=arm64 로 명시적 지정
    arm64 = {
      capacity_types    = ["spot", "on-demand"]
      instance_families = ["c", "m", "r"]
      architectures     = ["arm64"]
      instance_gen_min  = "2"
      weight            = 10
      taints            = []
      limits            = { cpu = "50", memory = "200Gi" }
    }

    # GPU 워크로드 — ML/AI 전용. 현재 미사용이나 설계상 포함
    # Taint: nvidia.com/gpu=true:NoSchedule → Toleration 없는 Pod는 배치 불가
    # OD 전용: GPU Spot은 가용성이 불안정하고 체크포인트 없는 학습 작업에서 복구 비용이 크다
    gpu = {
      capacity_types    = ["on-demand"]
      instance_families = ["p", "g"]
      architectures     = ["amd64"]
      instance_gen_min  = "3"
      weight            = 5
      taints = [{
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      }]
      limits = { cpu = "20", memory = "100Gi" }
    }

    # Spot 전용 — 중단을 감수하는 워크로드 강제 격리
    # Taint: spot-only=true:NoSchedule → Toleration 없는 Pod는 배치 불가
    # 사용 대상: 비용 절감이 최우선이고 중단 복구 로직을 갖춘 워크로드
    spot = {
      capacity_types    = ["spot"]
      instance_families = ["c", "m", "r"]
      architectures     = ["amd64"]
      instance_gen_min  = "2"
      weight            = 10
      taints = [{
        key    = "spot-only"
        value  = "true"
        effect = "NoSchedule"
      }]
      limits = { cpu = "100", memory = "400Gi" }
    }
  }
}
