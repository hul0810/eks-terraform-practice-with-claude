################################################################################
# EKS 클러스터 모듈
#
# terraform-aws-modules/eks v21.x 를 래핑하여 프로젝트 공통 설정을 캡슐화한다.
# 버전: 21.22.0 (2026-05-28 기준 최신)
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.22.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # ── 엔드포인트 접근 설정 ─────────────────────────────────────────────────────
  # private_access는 항상 활성화: 노드 ↔ 컨트롤 플레인 통신이 VPC 내부로 유지되어
  # 네트워크 비용 및 지연 시간을 줄이고, 외부 노출 없이 안전한 통신을 보장한다.
  # public_access는 환경별로 다름: develop=true(로컬 kubectl), production=false(VPN 경유)
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.public_access_cidrs

  # ── 컨트롤 플레인 로그 ───────────────────────────────────────────────────────
  # 기본 비활성화(빈 리스트)로 CloudWatch Logs 비용을 절감한다.
  # 디버깅이 필요할 때만 활성화: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  enabled_log_types = var.enabled_log_types

  # ── IRSA (IAM Roles for Service Accounts) ────────────────────────────────────
  # OIDC Provider를 생성하여 Pod가 IAM 역할을 직접 assume할 수 있게 한다.
  # Karpenter, AWS Load Balancer Controller, EBS CSI Driver 등 모든 AWS 연동 애드온의 전제 조건.
  # 노드 IAM 역할에 과도한 권한을 부여하는 대신 Pod별로 최소 권한을 부여할 수 있다.
  enable_irsa = true

  # ── 인증 모드 ────────────────────────────────────────────────────────────────
  # API_AND_CONFIG_MAP: 기존 aws-auth ConfigMap과 새로운 EKS Access Entry API를 동시에 지원.
  # Karpenter가 노드 등록 시 aws-auth ConfigMap을 사용하므로 이 모드가 필요하다.
  # (API 단독 모드에서는 Karpenter NodeClass의 노드 IAM 역할 자동 등록이 불가)
  authentication_mode = "API_AND_CONFIG_MAP"

  # ── KMS 암호화 ───────────────────────────────────────────────────────────────
  # develop 환경에서는 KMS 키 비용($1/월/키) 절감을 위해 비활성화.
  # 모듈 내부: enable_encryption_config = (var.encryption_config != null)
  # → null 로 명시해야 완전 비활성화. {} (빈 객체)는 null이 아니므로 오류 발생.
  # production: create_kms_key = true, encryption_config = { resources = ["secrets"] }
  create_kms_key    = false
  encryption_config = null

  # ── 핵심 클러스터 Add-on ──────────────────────────────────────────────────────
  # vpc-cni / kube-proxy / coredns는 클러스터 정상 동작의 전제 조건인 bootstrap add-on이다.
  # 이 블록이 없으면 EKS managed add-on이 하나도 생성되지 않아 노드가 CNI 초기화에
  # 실패하고 NotReady → NodeCreationFailure로 이어진다.
  #
  # vpc-cni before_compute = true: 노드 그룹 생성/갱신 전에 vpc-cni를 먼저 배포한다.
  # 노드가 조인하는 시점에 CNI가 이미 준비돼 있어야 /opt/cni/bin 초기화가 성공한다.
  #
  # 버전 고정 정책: most_recent 사용 금지. apply 시점마다 버전이 달라져 환경 간 일관성을
  # 보장할 수 없다. 업그레이드 시 docs/terraform-principles.md의 add-on 버전 정책 참조.
  #
  # 애플리케이션 레벨 add-on(LBC, EBS CSI, metrics-server 등)은
  # modules/eks-addons에서 별도로 관리한다.
  addons = {
    vpc-cni = {
      addon_version  = "v1.20.5-eksbuild.1"
      before_compute = true
    }
    kube-proxy = {
      addon_version = "v1.33.10-eksbuild.2"
    }
    coredns = {
      addon_version = "v1.12.4-eksbuild.10"
    }
  }

  # ── 시스템 Managed Node Group ────────────────────────────────────────────────
  # Karpenter 및 시스템 애드온(CoreDNS, kube-proxy, LBC 등)이 실행되는 전용 노드 풀.
  # Karpenter 자체가 기동되기 위한 노드가 필요하므로 MNG를 별도로 구성한다.
  # (Karpenter가 자기 자신을 스케줄링할 수 없는 부트스트랩 문제 해결)
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      ami_type       = var.system_node_ami_type

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      # ON_DEMAND 하드코딩: 이 노드 그룹은 Karpenter(클러스터 오토스케일러)가 실행되는 전용 노드다.
      # Karpenter는 Pod이므로 이 노드가 Spot 중단되면 신규 노드 프로비저닝이 불가능해진다.
      # 클러스터 자가 회복 능력을 보장하기 위해 변수화하지 않고 ON_DEMAND로 고정한다.
      # 비용 절감용 Spot은 Karpenter NodePool(앱 워크로드 레이어)에서 별도 적용한다.
      capacity_type = "ON_DEMAND"

      # 클러스터 SG를 노드에 직접 부착: kubelet → API 서버 443/tcp 통신 허용
      # 클러스터 SG 인바운드는 self-reference만 있으므로, 노드가 클러스터 SG를 가져야
      # endpoint_private_access=true 환경에서 컨트롤 플레인과 통신할 수 있다.
      # 기본값이 false이므로 반드시 명시해야 한다.
      attach_cluster_primary_security_group = true

      # role 레이블: Karpenter NodeAffinity 설정에서 시스템 노드를 선택할 때 사용
      labels = {
        role = "system"
      }

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

      # create_before_destroy = true 는 terraform-aws-modules/eks v21.x 서브모듈
      # (modules/eks-managed-node-group/main.tf) 내부에 이미 하드코딩되어 있다.
      # 외부에서 lifecycle 블록을 중복 선언하면 오류가 발생하므로 여기서는 생략한다.
    }
  }

  tags = var.additional_tags
}

################################################################################
# 노드 Security Group 추가 규칙
#
# terraform-aws-modules/eks v21.x가 node_security_group_recommended_rules로
# 기본 생성하는 규칙 목록:
#   - ingress_cluster_443 / ingress_cluster_kubelet
#   - ingress_self_coredns_tcp / ingress_self_coredns_udp
#   - ingress_nodes_ephemeral (1025-65535/tcp self)
#   - ingress_cluster_4443/6443/8443/9443/10251 (webhook 포트)
#   - egress_all (0.0.0.0/0 ALL)
#
# 아래는 모듈이 커버하지 않는 추가 규칙만 선언한다.
# ※ 인라인 ingress/egress 블록 금지 원칙에 따라 별도 리소스로 분리한다.
################################################################################

# 노드 간 전체 프로토콜 허용 (Self-reference)
# 모듈 기본값은 ephemeral 포트(1025-65535/tcp)와 DNS(53)만 허용한다.
# VPC CNI 환경에서 ICMP, UDP 애플리케이션 트래픽 등 비-TCP 프로토콜도
# 노드 간에 차단되지 않도록 ALL 프로토콜 self-reference 규칙을 추가한다.
resource "aws_vpc_security_group_ingress_rule" "node_to_node" {
  security_group_id            = module.eks.node_security_group_id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "-1"

  description = "Allow all traffic between nodes (ICMP, UDP app traffic beyond module defaults)"

  tags = var.additional_tags
}
