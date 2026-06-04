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
  # Karpenter, AWS Load Balancer Controller, EBS CSI Driver 등 모든 AWS 연동 애드온의 전제 조건.
  # 노드 IAM 역할에 과도한 권한을 부여하는 대신 Pod별로 최소 권한을 부여할 수 있다.
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

  # upstream 기본값(encryption_config = {})을 override해야 봉투 암호화가 비활성화됨
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
      # 클러스터 이름을 포함한 이름으로 AWS 콘솔에서 소속 클러스터를 즉시 식별할 수 있게 한다.
      name           = "${var.project}-system-${var.environment}"
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

      # EKS 자동 생성 SG(clusterSecurityGroupId)를 노드에 부착.
      # 이 SG의 inbound self-reference(ALL)가 노드 ↔ 컨트롤 플레인 양방향 통신을 허용한다.
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

      # IAM role name_prefix 한도(38자) 초과 방지: name_prefix 대신 name을 직접 사용(한도 64자).
      # {project}-system-{environment}-eks-node-group = 42자로 name_prefix 한도를 초과한다.
      iam_role_use_name_prefix = false

      # create_before_destroy = true 는 terraform-aws-modules/eks v21.x 서브모듈
      # (modules/eks-managed-node-group/main.tf) 내부에 이미 하드코딩되어 있다.
      # 외부에서 lifecycle 블록을 중복 선언하면 오류가 발생하므로 여기서는 생략한다.
    }
  }

  # ── 노드 간 추가 규칙 ────────────────────────────────────────────────────────
  # node_security_group_enable_recommended_rules가 커버하지 않는 비-TCP 프로토콜
  # (ICMP, UDP 애플리케이션 트래픽 등)을 노드 간에 허용한다.
  # 모듈 소유 SG의 규칙은 외부 리소스 주입 대신 모듈 파라미터로 관리한다.
  node_security_group_additional_rules = var.node_security_group_additional_rules

  zonal_shift_config = var.zonal_shift_config

  access_entries = var.access_entries

  tags = var.additional_tags
}
