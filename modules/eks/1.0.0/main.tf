################################################################################
# EKS 클러스터 모듈
#
# terraform-aws-modules/eks v21.22.0 를 래핑하여 프로젝트 공통 설정을 캡슐화한다.
# 버전: 21.22.0 (2026-05-28 기준 최신)
#
# 애드온 배포 순서 설계 (before_compute 기반 단일 모듈):
#   before_compute = true  → 노드 그룹보다 먼저 배포 (클러스터 생성 직후)
#     - eks-pod-identity-agent: aws-node Pod Identity 크레덴셜 획득의 전제 조건
#     - vpc-cni: 노드 조인 시 CNI 초기화 실패 방지 (ACTIVE 보장 후 노드 조인)
#   before_compute = false (기본값) → 모듈이 노드 그룹 완료 후 자동으로 depends_on 추가
#     - kube-proxy, aws-ebs-csi-driver: 노드 없어도 EKS가 즉시 ACTIVE 표시
#     - coredns: Kubernetes Deployment — 노드 없이는 ACTIVE 불가. before_compute = false로
#       선언하면 모듈이 depends_on = [module.eks_managed_node_group]을 자동 추가하여
#       이전 3단계 분리(Phase 1/2/3) 없이 동일한 안전성을 보장한다.
#     - aws-secrets-store-csi-driver-provider: DaemonSet — 노드 없이는 ACTIVE 불가. coredns와 동일 패턴.
#     - cert-manager: Deployment — 노드 없이는 ACTIVE 불가. coredns와 동일 패턴. AWS API 미호출로 IAM 불필요.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.22.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # ── 추가 보안 그룹 (cluster_sg) ─────────────────────────────────────────────
  # 모듈이 생성하여 EKS owned ENI에 추가로 부착하는 SG.
  # 노드 ↔ 컨트롤 플레인 기본 통신은 clusterSecurityGroupId self-reference(ALL)로 충분하지만,
  # 이 SG는 Bastion/VPN 등 외부 접근 제어 규칙을 추가할 때 앵커 역할을 한다.
  # 기본값이 true이지만 의도를 명시한다.
  #
  # [모듈 버그] create_security_group = false 설정 시 주의 — 사실상 false는 사용 불가:
  #   1. false로 설정하면 security_group_id(기본값 "")가 빈 문자열이 되어
  #      ingress_cluster_443/kubelet 규칙의 source_security_group_id = ""로 AWS API 요청이 가고
  #      SG 규칙 생성이 무기한 블로킹된다.
  #   2. 회피하려면 security_group_id에 기존 SG를 지정해야 하나,
  #      EKS clusterSecurityGroupId(eks-cluster-sg-*)는 AWS API 제약으로 추가 SG 등록 자체가 불가.
  #   3. 결국 false를 사용하려면 완전히 별도로 생성한 외부 SG가 있어야 하므로 현실적으로 true가 필수.
  create_security_group = true

  # ── 노드 권장 규칙 활성화 ────────────────────────────────────────────────────
  # egress_all, CoreDNS(53), ephemeral(1025-65535), webhook(4443/6443/8443/9443/10251) 포함.
  # false로 끄면 노드 egress가 사라져 ECR Pull, AWS API 호출 불가.
  # 기본값이 true이지만 의도를 명시한다.
  node_security_group_enable_recommended_rules = true

  # ── 엔드포인트 접근 설정 ─────────────────────────────────────────────────────
  # private_access는 항상 활성화: 노드 ↔ 컨트롤 플레인 통신이 VPC 내부로 유지되어
  # 네트워크 비용 및 지연 시간을 줄이고, 외부 노출 없이 안전한 통신을 보장한다.
  # public_access는 환경별로 다름: develop=true(로컬 kubectl), production=false(VPN 경유)
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # ── 컨트롤 플레인 로그 ───────────────────────────────────────────────────────
  # 기본 비활성화(빈 리스트)로 CloudWatch Logs 비용을 절감한다.
  # 디버깅이 필요할 때만 활성화: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  enabled_log_types = var.enabled_log_types

  # ── 봉투암호화 비활성화 ──────────────────────────────────────────────────────
  # encryption_config 기본값이 {}(null 아님)이므로 모듈 내부에서 enable_encryption_config = true로 평가된다.
  # null로 명시해야 encryption_config 블록 자체가 생성되지 않아 key_arn required 에러를 피할 수 있다.
  # EKS etcd는 AWS 관리형 암호화(AES-256)로 기본 보호된다.
  # Kubernetes secrets 봉투암호화(CMK)가 필요해지면 외부 KMS ARN을 provider_key_arn에 지정한다.
  create_kms_key           = false
  attach_encryption_policy = false
  encryption_config        = null

  # ── IRSA (IAM Roles for Service Accounts) ────────────────────────────────────
  # OIDC Provider를 생성하여 Pod가 IAM 역할을 직접 assume할 수 있게 한다.
  # 이 프로젝트의 기본 IAM 전략은 Pod Identity이지만, 서드파티 도구나 특정 상황에서
  # IRSA가 필요할 수 있으므로 OIDC Provider는 활성화 상태로 유지한다.
  enable_irsa = true

  # ── 인증 모드 ────────────────────────────────────────────────────────────────
  # API_AND_CONFIG_MAP: 기존 aws-auth ConfigMap과 새로운 EKS Access Entry API를 동시에 지원.
  # Karpenter가 노드 등록 시 aws-auth ConfigMap을 사용하므로 이 모드가 필요하다.
  # (API 단독 모드에서는 Karpenter NodeClass의 노드 IAM 역할 자동 등록이 불가)
  authentication_mode = "API_AND_CONFIG_MAP"

  # ── 클러스터 생성자 접근 권한 ────────────────────────────────────────────────
  # 이 옵션을 true로 설정하면 terraform apply를 실행한 IAM 엔티티(현재: TerraformExecutionRole)에
  # AmazonEKSClusterAdminPolicy를 Access Entry로 자동 부여한다.
  #
  # false로 유지하는 이유:
  #   - TerraformExecutionRole은 AWS API(EKS 생성/수정)만 호출하므로 K8s ClusterAdmin 불필요
  #   - 클러스터 접근 주체는 environments/.../eks/locals.tf의 access_entries에 명시적으로 선언한다
  #     → 누가 어떤 권한으로 접근하는지 코드로 추적 가능
  enable_cluster_creator_admin_permissions = false

  # ── 애드온 (before_compute 기반 배포 순서 제어) ──────────────────────────────
  # 버전 고정 정책: most_recent 사용 금지. 버전 조회: docs/addon-strategy.md 참조.
  addons = {
    # eks-pod-identity-agent를 vpc-cni보다 먼저 등록해야 aws-node가
    # 노드 기동 시 Pod Identity 크레덴셜을 즉시 획득할 수 있다.
    eks-pod-identity-agent = {
      addon_version  = var.addon_versions.eks_pod_identity_agent
      before_compute = true
    }
    vpc-cni = {
      addon_version = var.addon_versions.vpc_cni
      # 노드가 조인하기 전 vpc-cni가 ACTIVE 상태여야 CNI 초기화 실패가 발생하지 않는다.
      before_compute = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }
    kube-proxy = {
      addon_version = var.addon_versions.kube_proxy
      # before_compute 기본값 false: EKS가 노드 없이도 즉시 ACTIVE 표시.
      # 모듈이 depends_on = [module.eks_managed_node_group]을 자동 추가한다.
    }
    coredns = {
      addon_version               = var.addon_versions.coredns
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values        = var.coredns_configuration_values
      # before_compute 기본값 false: Kubernetes Deployment이므로 노드 없이는 ACTIVE 불가.
      # 모듈이 depends_on = [module.eks_managed_node_group]을 자동 추가하여
      # 노드 그룹 완료 후 설치되도록 보장한다 — 외부 aws_eks_addon 분리 불필요.
    }
    aws-ebs-csi-driver = {
      addon_version               = var.addon_versions.ebs_csi_driver
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values        = var.ebs_csi_configuration_values
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
      # before_compute 기본값 false: EKS가 노드 없이도 즉시 ACTIVE 표시.
    }
    aws-secrets-store-csi-driver-provider = {
      addon_version               = var.addon_versions.secrets_store_csi_driver
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      # before_compute 기본값 false: DaemonSet이므로 노드 없이는 ACTIVE 불가.
      # 모듈이 depends_on = [module.eks_managed_node_group]을 자동 추가한다.
      # IAM 불필요 — Secrets Manager/SSM 접근 IAM은 앱 Pod ServiceAccount에 별도 부여한다.
    }
    cert-manager = {
      addon_version               = var.addon_versions.cert_manager
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      configuration_values        = var.cert_manager_configuration_values
      # before_compute 기본값 false: Deployment이므로 노드 없이는 ACTIVE 불가.
      # 모듈이 depends_on = [module.eks_managed_node_group]을 자동 추가한다.
      # IAM 불필요 — AWS API를 직접 호출하지 않는다.
      # EKS 커뮤니티 애드온(2025-03 출시). secrets-store-csi-driver와 동일한 Bootstrap 분류 근거.
    }
  }

  # ── 시스템 Managed Node Group ─────────────────────────────────────────────────
  # Karpenter 및 시스템 애드온(CoreDNS, kube-proxy, LBC 등)이 실행되는 전용 노드 풀.
  # Karpenter 자체가 기동되기 위한 노드가 필요하므로 MNG를 별도로 구성한다.
  # (Karpenter가 자기 자신을 스케줄링할 수 없는 부트스트랩 문제 해결)
  #
  # before_compute = true 애드온(vpc-cni, eks-pod-identity-agent)이 모두 ACTIVE된 후
  # 이 노드 그룹이 생성된다. 모듈이 내부적으로 before_compute 애드온 완료를 전제로
  # 노드 그룹을 생성하므로, 노드 조인 시점의 CNI 초기화 경쟁 조건이 발생하지 않는다.
  #
  # cluster_primary_security_group_id, vpc_security_group_ids를 별도 지정하지 않는 이유:
  #   eks_managed_node_groups 스키마에 해당 파라미터가 없다. 모듈이 클러스터 SG(clusterSecurityGroupId)와
  #   node_sg를 노드 그룹에 자동으로 부착한다 — 외부 서브모듈 호출 시 수동 지정이 필요했던 부분.
  eks_managed_node_groups = {
    system = {
      name           = "${var.project}-system-${var.environment}"
      subnet_ids     = var.subnet_ids
      instance_types = var.system_node_instance_types
      ami_type       = var.system_node_ami_type
      min_size       = var.system_node_min_size
      max_size       = var.system_node_max_size
      desired_size   = var.system_node_desired_size

      # ON_DEMAND 하드코딩: 이 노드 그룹은 Karpenter(클러스터 오토스케일러)가 실행되는 전용 노드다.
      # Karpenter는 Pod이므로 이 노드가 Spot 중단되면 신규 노드 프로비저닝이 불가능해진다.
      # 클러스터 자가 회복 능력을 보장하기 위해 변수화하지 않고 ON_DEMAND로 고정한다.
      # 비용 절감용 Spot은 Karpenter NodePool(앱 워크로드 레이어)에서 별도 적용한다.
      capacity_type = "ON_DEMAND"

      # role 레이블: Karpenter NodeAffinity 설정에서 시스템 노드를 선택할 때 사용
      labels = { role = "system" }

      # CriticalAddonsOnly taint: 일반 워크로드 Pod가 시스템 노드에 스케줄되지 않도록 격리.
      # 시스템 노드는 사양이 작으므로 일반 워크로드와 리소스를 공유하면 시스템 컴포넌트 OOM 위험.
      # Karpenter, CoreDNS 등 시스템 컴포넌트는 toleration을 명시하여 허용한다.
      taints = {
        CriticalAddonsOnly = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # IAM role name_prefix 한도(38자) 초과 방지: name_prefix 대신 name을 직접 사용(한도 64자).
      # {project}-system-{environment}-eks-node-group = 42자로 name_prefix 한도를 초과한다.
      iam_role_use_name_prefix = false

      # vpc-cni는 Pod Identity로 IAM 권한을 획득하므로 노드 IAM Role에 AmazonEKS_CNI_Policy 불필요.
      # AWS 권장 사항: Pod Identity/IRSA 사용 시 노드 Role에서 CNI 정책 제거.
      iam_role_attach_cni_policy = false
    }
  }

  # ── 노드 간 추가 규칙 ────────────────────────────────────────────────────────
  # node_security_group_enable_recommended_rules가 커버하지 않는 비-TCP 프로토콜
  # (ICMP, UDP 애플리케이션 트래픽 등)을 노드 간에 허용한다.
  # 모듈 소유 SG의 규칙은 외부 리소스 주입 대신 모듈 파라미터로 관리한다.
  node_security_group_additional_rules = var.node_security_group_additional_rules

  # EC2NodeClass의 securityGroupSelectorTerms[].tags 필터와 이 태그 값이 일치해야
  # Karpenter가 올바른 node SG를 선택한다. 값이 cluster_name과 다르면 SG 0개 탐색으로
  # 노드 프로비저닝이 실패한다. node_sg는 모든 노드에 부착되므로 단일 태그로 탐색 가능.
  node_security_group_tags = var.node_security_group_tags

  upgrade_policy     = var.upgrade_policy
  zonal_shift_config = var.zonal_shift_config

  access_entries = var.access_entries

  tags = var.additional_tags
}

################################################################################
# Bootstrap 애드온 IAM Role — Pod Identity
#
# Terraform은 선언 순서가 아닌 의존성 그래프로 실행 순서를 결정한다.
# module.eks가 아래 Role ARN을 참조하므로 Terraform이 이 Role들을 먼저 생성한다.
# Pod Identity는 OIDC Provider ARN이 불필요하여 module.eks에 의존하지 않는다.
################################################################################

# ── VPC CNI (aws-node) ────────────────────────────────────────────────────────
# 노드 IAM Role에서 AmazonEKS_CNI_Policy를 제거하고 aws-node ServiceAccount에만 부여한다.
resource "aws_iam_role" "vpc_cni" {
  name        = "${var.cluster_name}-vpc-cni"
  description = "VPC CNI Pod Identity IAM Role - ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = var.additional_tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ── EBS CSI Driver (ebs-csi-controller-sa) ───────────────────────────────────
# AmazonEBSCSIDriverPolicy를 사용한다.
# (describe-addon-configuration 반환값은 V2이나 실제 IAM에 존재하지 않는 정책명이므로 원본 사용)
resource "aws_iam_role" "ebs_csi" {
  name        = "${var.cluster_name}-ebs-csi-driver"
  description = "EBS CSI Driver Pod Identity IAM Role - ${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
      }
    ]
  })

  tags = var.additional_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
