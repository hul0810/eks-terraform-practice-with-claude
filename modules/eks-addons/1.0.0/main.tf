################################################################################
# EKS Addons 모듈 — Helm (blueprints) 전용
#
# 관리 범위: AWS LB Controller, ExternalDNS, Metrics Server, Karpenter
#
# 이 모듈은 EKS 관리형 addon API(aws_eks_addon)가 없거나 Helm values 커스터마이징이
# 필요한 애드온을 aws-ia/eks-blueprints-addons 모듈로 관리한다.
#
# [EBS CSI Driver를 여기서 관리하지 않는 이유]
# EBS CSI는 Bootstrap 애드온으로 분류되어 modules/eks에서 관리한다.
# (docs/addon-strategy.md의 "설치 방식 결정 기준" 참조)
#
# [IAM 전략: IRSA]
# blueprints 모듈이 IRSA를 표준으로 지원한다.
# oidc_provider_arn을 받아 blueprints 내부에서 IAM Role 생성과
# Helm values serviceAccount.annotations 주입을 자동 처리한다.
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.23.0"

  cluster_name      = var.cluster_name
  cluster_endpoint  = var.cluster_endpoint
  cluster_version   = var.cluster_version
  oidc_provider_arn = var.oidc_provider_arn

  # ── AWS Load Balancer Controller ─────────────────────────────────────────────
  # EKS 관리형 addon이 없는 Helm-only 컴포넌트. blueprints가 IRSA 자동 처리.
  enable_aws_load_balancer_controller = var.enable_aws_load_balancer_controller
  aws_load_balancer_controller = {
    chart_version = var.lbc_chart_version
    set = [
      # LBC v3.x는 vpcId 미지정 시 IMDS에서 VPC ID를 조회한다.
      # Pod에서 IMDSv2 hop limit(기본 1) 초과로 IMDS 접근이 불가하므로 직접 주입한다.
      { name = "vpcId", value = var.vpc_id },
      # 기본값 2 — dev는 replica_counts.lbc=1로 낮춰 시스템 노드 리소스를 확보한다
      { name = "replicaCount", value = tostring(var.replica_counts.lbc) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key",      value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect",   value = "NoSchedule" },
    ]
  }

  # ── ExternalDNS ───────────────────────────────────────────────────────────────
  # Route53 zone 설정 등 Helm values 커스터마이징이 필요하여 Helm으로 관리한다.
  # blueprints가 IRSA 자동 처리.
  enable_external_dns            = var.enable_external_dns
  external_dns_route53_zone_arns = var.external_dns_route53_zone_arns
  external_dns = {
    chart_version = var.external_dns_chart_version
    set = [
      # 기본값 1이나 명시적으로 관리
      { name = "replicaCount", value = tostring(var.replica_counts.external_dns) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key",      value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect",   value = "NoSchedule" },
    ]
  }

  # ── Metrics Server ────────────────────────────────────────────────────────────
  # 순수 오픈소스. IAM 불필요.
  enable_metrics_server = var.enable_metrics_server
  metrics_server = {
    chart_version = var.metrics_server_chart_version
    set = [
      # 기본값 1이나 명시적으로 관리
      { name = "replicas", value = tostring(var.replica_counts.metrics_server) },
      # 시스템 노드(CriticalAddonsOnly taint)에 스케줄 — 인프라 컴포넌트이므로 앱 노드와 분리
      { name = "tolerations[0].key",      value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect",   value = "NoSchedule" },
    ]
  }

  # ── Karpenter ─────────────────────────────────────────────────────────────────
  # blueprints가 컨트롤러 IAM Role, SQS 인터럽션 큐, EventBridge Rule, Helm chart를 통합 처리.
  # NodeClass / NodePool은 Kubernetes 리소스이므로 별도 관리한다.
  enable_karpenter = var.enable_karpenter
  karpenter = {
    chart_version = var.karpenter_chart_version
    set = [
      # 기본값 2 — dev는 replica_counts.karpenter=1로 낮춰 시스템 노드 Pending 해소
      { name = "replicas", value = tostring(var.replica_counts.karpenter) },
      # 시스템 노드에 스케줄 — Karpenter 자체가 앱 노드에서 실행되면 부트스트랩 문제 발생
      { name = "tolerations[0].key",      value = "CriticalAddonsOnly" },
      { name = "tolerations[0].operator", value = "Exists" },
      { name = "tolerations[0].effect",   value = "NoSchedule" },
    ]
  }

  tags = var.additional_tags
}
