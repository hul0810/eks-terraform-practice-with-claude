################################################################################
# EKS 클러스터 모듈
#
# terraform-aws-modules/eks v21.x 를 래핑하여 프로젝트 공통 설정을 캡슐화한다.
# 버전: 21.22.0 (2026-05-28 기준 최신)
#
# 노드 그룹 분리 설계:
#   module "eks"        → 클러스터 + 모든 애드온 (노드 그룹 없음)
#   module "system_node_group" → 노드 그룹만, depends_on = [module.eks]
#
# before_compute = true는 해당 addon 리소스의 depends_on만 제거할 뿐,
# 노드 그룹이 addon 완료를 기다리는 의존성은 생성하지 않는다.
# 결과적으로 addon과 노드 그룹이 병렬 생성되어 vpc-cni ACTIVE 전에 노드가
# 조인을 시도하고 CNI 초기화에 실패할 수 있다.
# 이를 해결하기 위해 노드 그룹을 module "eks" 외부로 분리하고
# depends_on = [module.eks]로 명시적 순서를 강제한다.
################################################################################

################################################################################
# Bootstrap 애드온 IAM Role — Pod Identity
#
# module.eks 호출 전에 선언한다. Pod Identity는 OIDC Provider ARN이 불필요하므로
# module.eks에 의존하지 않아 순환 의존성이 발생하지 않는다.
# IAM Role ARN을 addons 블록의 pod_identity_association으로 전달한다.
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
# AWS가 권장하는 최신 정책인 AmazonEBSCSIDriverPolicyV2를 사용한다.
# (describe-addon-configuration 조회 결과 기준 — 구버전 AmazonEBSCSIDriverPolicy 대체)
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
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicyV2"
}

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

  # ── Bootstrap Add-on ─────────────────────────────────────────────────────────
  # 클러스터 초기화 시 함께 배포되는 필수 add-on.
  # 이 블록이 없으면 노드가 CNI 초기화에 실패하고 NotReady → NodeCreationFailure로 이어진다.
  #
  # 노드 그룹(module "system_node_group")이 depends_on = [module.eks]로 선언되어 있으므로
  # module.eks 전체(클러스터 + 모든 애드온 ACTIVE)가 완료된 후에 노드 그룹이 생성된다.
  # vpc-cni가 ACTIVE 상태가 보장된 시점에 노드가 조인하므로 CNI 초기화 실패가 발생하지 않는다.
  #
  # 버전 고정 정책: most_recent 사용 금지. 버전 조회: docs/addon-strategy.md 참조.
  addons = {
    vpc-cni = {
      addon_version = var.addon_versions.vpc_cni
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }
    kube-proxy = {
      addon_version = var.addon_versions.kube_proxy
    }
    coredns = {
      addon_version = var.addon_versions.coredns
    }
    # vpc-cni의 Pod Identity 사용 전제 조건.
    # agent가 EKS API에 먼저 등록되어야 aws-node가 Pod Identity 크레덴셜을 획득할 수 있다.
    eks-pod-identity-agent = {
      addon_version = var.addon_versions.eks_pod_identity_agent
    }
    # Pod Identity IAM Role을 addons 블록 내 pod_identity_association으로 연결한다.
    # role_arn은 module.eks 호출 전에 생성된 aws_iam_role.ebs_csi를 참조한다 (순환 의존성 없음).
    aws-ebs-csi-driver = {
      addon_version               = var.addon_versions.ebs_csi_driver
      resolve_conflicts_on_update = "OVERWRITE"
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # ── 노드 간 추가 규칙 ────────────────────────────────────────────────────────
  # node_security_group_enable_recommended_rules가 커버하지 않는 비-TCP 프로토콜
  # (ICMP, UDP 애플리케이션 트래픽 등)을 노드 간에 허용한다.
  # 모듈 소유 SG의 규칙은 외부 리소스 주입 대신 모듈 파라미터로 관리한다.
  node_security_group_additional_rules = var.node_security_group_additional_rules

  upgrade_policy     = var.upgrade_policy
  zonal_shift_config = var.zonal_shift_config

  access_entries = var.access_entries

  tags = var.additional_tags
}

################################################################################
# 시스템 Managed Node Group
#
# Karpenter 및 시스템 애드온(CoreDNS, kube-proxy, LBC 등)이 실행되는 전용 노드 풀.
# Karpenter 자체가 기동되기 위한 노드가 필요하므로 MNG를 별도로 구성한다.
# (Karpenter가 자기 자신을 스케줄링할 수 없는 부트스트랩 문제 해결)
#
# 분리 이유: depends_on = [module.eks]로 모든 애드온(vpc-cni 포함)이 ACTIVE된 후에
# 노드 그룹을 생성하여 노드 조인 시점의 CNI 초기화 실패를 방지한다.
# module "eks" 내부 eks_managed_node_groups는 애드온과 병렬로 생성되어
# vpc-cni ACTIVE 전에 노드가 조인을 시도하는 경쟁 조건이 발생했다.
################################################################################
module "system_node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 21.22.0"

  # ── 클러스터 연결 ─────────────────────────────────────────────────────────────
  # module.eks가 완전히 완료(= 모든 애드온 ACTIVE)된 후 노드 그룹을 생성한다.
  cluster_name        = module.eks.cluster_name
  cluster_endpoint    = module.eks.cluster_endpoint
  cluster_auth_base64 = module.eks.cluster_certificate_authority_data
  cluster_ip_family   = "ipv4"
  cluster_service_cidr = module.eks.cluster_service_cidr

  # ── 노드 그룹 기본 설정 ──────────────────────────────────────────────────────
  # 클러스터 이름을 포함한 이름으로 AWS 콘솔에서 소속 클러스터를 즉시 식별할 수 있게 한다.
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

  # ── Security Group 연결 ───────────────────────────────────────────────────────
  # EKS 자동 생성 SG(clusterSecurityGroupId)를 노드에 부착.
  # 이 SG의 inbound self-reference(ALL)가 노드 ↔ 컨트롤 플레인 양방향 통신을 허용한다.
  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  # 모듈이 생성한 node_sg를 명시적으로 연결한다.
  # node_security_group_enable_recommended_rules 규칙(egress_all, CoreDNS, webhook 등)이
  # 이 SG에 적용되어 있으므로 반드시 포함해야 한다.
  vpc_security_group_ids = [module.eks.node_security_group_id]

  # ── Kubernetes 레이블 및 Taint ──────────────────────────────────────────────
  # role 레이블: Karpenter NodeAffinity 설정에서 시스템 노드를 선택할 때 사용
  labels = { role = "system" }

  # CriticalAddonsOnly taint: 일반 워크로드 Pod가 시스템 노드에 스케줄되지 않도록 격리.
  # Karpenter, CoreDNS 등 DaemonSet/Deployment는 toleration을 명시하여 허용.
  # effect는 EKS API 형식인 대문자 스네이크 케이스를 사용해야 한다 (NO_SCHEDULE).
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

  # AmazonEKS_CNI_Policy를 노드 역할에 유지한다 (기본값 true).
  # Pod Identity가 런타임의 기본 크레덴셜 방식이지만, 첫 노드 부트스트랩 시
  # eks-pod-identity-agent DaemonSet과 aws-node DaemonSet이 동시에 시작되어
  # agent가 준비되기 전에 aws-node가 크레덴셜을 요청할 수 있다.
  # 노드 역할의 AmazonEKS_CNI_Policy가 이 시점의 fallback을 제공한다.
  # (aws-node는 Pod Identity > 노드 역할 순으로 크레덴셜을 선택한다)

  # create_before_destroy = true 는 terraform-aws-modules/eks v21.x 서브모듈
  # (modules/eks-managed-node-group/main.tf) 내부에 이미 하드코딩되어 있다.
  # 외부에서 lifecycle 블록을 중복 선언하면 오류가 발생하므로 여기서는 생략한다.

  tags = var.additional_tags

  # module.eks 전체(클러스터 + vpc-cni 포함 모든 애드온 ACTIVE)가 완료된 후 노드 그룹을 생성한다.
  depends_on = [module.eks]
}
