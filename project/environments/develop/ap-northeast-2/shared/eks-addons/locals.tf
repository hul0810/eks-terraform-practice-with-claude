locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

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

  # dev: 시스템 노드 1개(비용 절감)로 모든 애드온 replica=1. prd는 모듈 기본값 사용
  replica_counts = {
    lbc            = 1
    karpenter      = 1
    external_dns   = 1
    metrics_server = 1
    argo_rollouts  = 1
  }

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전
    # 버전 업그레이드: helm repo update && helm search repo <chart> --versions
    lbc_chart_version             = "3.4.0"
    external_dns_chart_version    = "1.14.5"
    metrics_server_chart_version  = "3.12.2"
    karpenter_chart_version       = "1.12.1"
    argocd_chart_version          = "9.5.21"
    argo_rollouts_chart_version   = "2.38.1"

    enable_aws_load_balancer_controller = true
    enable_argo_rollouts                = true
    enable_external_dns                 = true
    # pyhtest.com zone ARN 추가 → ExternalDNS IRSA Role 신규 생성 (이전엔 zone_arns=[]로 미생성 상태였음)
    external_dns_route53_zone_arns = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.pyhtest.zone_id}"]
    enable_metrics_server          = true
    enable_karpenter               = true
    enable_argocd                  = true
    argocd_ha_enabled              = false # dev: 단일 시스템 노드, 비용 절감 (redis-ha 등 추가 pod 회피)
    argocd_ingress_enabled         = true
    argocd_ingress_hostname        = "argocd-develop.pyhtest.com"
    argocd_ingress_alb_name        = "${local.project}-argocd${local.name_suffix}-alb"
    # dex 비활성화 상태(기본 admin 계정만 인증)이므로 ALB SG inbound를 내 IP로 제한
    argocd_ingress_allowed_cidrs = ["OPERATOR_IP/32"]

    # ArgoCD admin 초기 패스워드 (bcrypt 해시). 해시 생성일: 2026-06-16
    # 패스워드 변경 시: 새 해시와 argocd_admin_password_mtime을 함께 갱신해야 ArgoCD가 변경을 감지한다.
    # 해시 재생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt()).decode())"
    # 주의: Terraform bcrypt() 함수를 직접 사용하지 말 것 — apply마다 ArgoCD pod 재시작 유발
    argocd_admin_password_bcrypt = "ARGOCD_HASH_REDACTED"
    argocd_admin_password_mtime  = "2026-06-16T00:00:00Z"

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
