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

  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids

  eks = {
    cluster_name       = "${local.project}${local.name_suffix}"
    kubernetes_version = "1.33"

    addon_versions = {
      # 버전 조회: aws eks describe-addon-versions --kubernetes-version 1.33 --region ap-northeast-2
      # 2026-06-05 기준 default 버전 (cert-manager: 2026-06-24 기준)
      vpc_cni                  = "v1.20.5-eksbuild.1"
      kube_proxy               = "v1.33.10-eksbuild.2"
      coredns                  = "v1.12.4-eksbuild.10"
      eks_pod_identity_agent   = "v1.3.10-eksbuild.3"
      ebs_csi_driver           = "v1.60.1-eksbuild.1"
      secrets_store_csi_driver = "v3.1.1-eksbuild.1"
      cert_manager             = "v1.20.2-eksbuild.3"
    }

    # develop: 로컬 PC에서 kubectl 직접 접근 편의를 위해 public 엔드포인트 허용
    # production: false로 변경 후 VPN/Bastion 경유
    endpoint_public_access = true

    # 로컬 kubectl 접근을 허용할 IP 목록. 공인 IP가 변경되면 갱신 후 terraform apply.
    public_access_cidrs = ["1.226.228.52/32"]

    # 컨트롤 플레인 로그: CloudWatch Logs 비용 발생 (로그 타입당 약 $0.50/GB~)
    # 기본 비활성화. 디버깅 필요 시 원하는 타입 추가 후 terraform apply.
    # 가능한 값: "api", "audit", "authenticator", "controllerManager", "scheduler"
    enabled_log_types = []

    system_node = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      desired_size   = 1
    }

    # dev: t3.medium 시스템 노드 pod 한계(17)에서 secrets-store DaemonSet 2개를 위한 슬롯 확보.
    # CoreDNS·EBS CSI Controller·cert-manager를 1 replica로 축소하여 시스템 노드 슬롯을 절약한다.
    # 재시작 시 수초 단절 허용 — dev 환경 비용 예외 (production은 기본값 2 유지).
    coredns_configuration_values = jsonencode({ replicaCount = 1 })
    ebs_csi_configuration_values = jsonencode({ controller = { replicaCount = 1 } })
    # cert-manager: replicaCount=1(controller·webhook·cainjector), CriticalAddonsOnly toleration으로 시스템 노드 배치
    cert_manager_configuration_values = jsonencode({
      installCRDs  = true
      replicaCount = 1
      tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      webhook = {
        replicaCount = 1
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      }
      cainjector = {
        replicaCount = 1
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      }
    })

    # STANDARD: 표준 지원 종료 시 다음 버전으로 자동 업그레이드 — Extended Support 비용($0.60/hr) 차단
    # EKS 1.33 표준 지원 종료: 2026-07-29. 이전에 1.34로 업그레이드하거나 자동 업그레이드 허용.
    upgrade_policy = { support_type = "STANDARD" }

    # Karpenter EC2NodeClass가 karpenter.sh/discovery 태그로 node SG를 자동 탐색한다.
    # 값은 EC2NodeClass의 securityGroupSelectorTerms와 일치해야 한다.
    node_security_group_tags = {
      "karpenter.sh/discovery" = "${local.project}${local.name_suffix}"
    }
  }

  # EKS 클러스터 접근 주체 목록
  # 클러스터가 재생성되어도 접근 권한이 자동 복원되도록 Terraform으로 관리한다.
  # principal_arn: IAM User 또는 Role ARN
  # policy_associations: principal당 여러 정책을 map으로 선언 가능
  #   policy_arn: AmazonEKSClusterAdminPolicy (클러스터 전체 admin)
  #               AmazonEKSEditPolicy (네임스페이스 수준 편집)
  #               AmazonEKSViewPolicy (읽기 전용)
  # access_scope.type: "cluster" (전체) 또는 "namespace" (특정 네임스페이스)
  # access_scope.namespaces: type이 "namespace"일 때만 지정
  access_entries = {
    study = {
      principal_arn = "arn:aws:iam::891396992584:user/study"
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # helm/kubernetes provider가 aws eks get-token --role-arn으로 이 Role을 assume하므로 클러스터 admin 권한 필요
    terraform_execution = {
      principal_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
