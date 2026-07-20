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
    kubernetes_version = "1.34"

    addon_versions = {
      # 버전 조회: aws eks describe-addon-versions --kubernetes-version 1.34 --region ap-northeast-2
      # 2026-06-24 기준 default 버전
      vpc_cni                = "v1.21.2-eksbuild.2"
      kube_proxy             = "v1.34.6-eksbuild.11"
      coredns                = "v1.12.4-eksbuild.17"
      eks_pod_identity_agent = "v1.3.10-eksbuild.3"
      ebs_csi_driver         = "v1.62.0-eksbuild.1"
      cert_manager           = "v1.20.2-eksbuild.3"
    }

    # develop: 로컬 PC에서 kubectl 직접 접근 편의를 위해 public 엔드포인트 허용
    # production: false로 변경 후 VPN/Bastion 경유
    endpoint_public_access = true

    # 로컬 kubectl 접근을 허용할 IP 목록. 공인 IP가 변경되면 갱신 후 terraform apply.
    # Phase 6-5: monitoring의 ArgoCD Hub가 이 클러스터의 EKS API에 접근하려면 monitoring
    # NAT Gateway의 공인 IP도 허용해야 한다 — VPC Peering(pcx-07fa1a0e9eb100e47)은 이미
    # 있지만 이 클러스터의 endpoint_private_access가 꺼져있어 지금은 public 경로로만 접근
    # 가능하다(argocd-k8s-auth 타임아웃으로 실제 확인 — exit code 20). 이 IP는 monitoring
    # vpc/outputs.tf의 nat_public_ips 참고.
    #
    # [알려진 리스크 — aws-architect 리뷰 지적, 2026-07-21] NAT Gateway는 EIP를 고정하지
    # 않으므로 monitoring teardown→재provision마다 이 IP가 바뀐다. 갱신을 깜빡하면
    # Hub→spoke 크로스 계정 인증이 "무성으로"(에러 없이 타임아웃만) 실패한다 — 이 세션에서
    # 실제로 monitoring teardown을 진행했으므로 다음 monitoring provision 후에는 이 값이
    # 이미 stale하다. 근본 해결책은 CIDR을 계속 갱신하는 게 아니라
    # `endpoint_private_access = true`로 켜고 기존 VPC Peering 경로로 완전히 옮기는 것 —
    # TODO_LIST.md "Phase 6 이후 백로그" 참조.
    public_access_cidrs = [var.operator_ip_cidr, "43.200.108.10/32"]

    # 컨트롤 플레인 로그: CloudWatch Logs 비용 발생 (로그 타입당 약 $0.50/GB~)
    # 기본 비활성화. 디버깅 필요 시 원하는 타입 추가 후 terraform apply.
    # 가능한 값: "api", "audit", "authenticator", "controllerManager", "scheduler"
    enabled_log_types = []

    system_node = {
      # t3a.medium(AMD)을 추가해 Spot 풀을 다양화한다 — t3(Intel)와 물리적으로 다른 용량
      # 풀이라 동시 회수 상관관계가 낮다. 두 타입 모두 2vCPU/4GiB 동일 스펙(파드 한도 유지)이며,
      # 온디맨드 가격이 t3.medium($0.0520/hr, ap-northeast-2) 이하인 것만 선택했다
      # (t3a.medium $0.0468/hr — 2026-07-08 조회. t2.medium/c5.large/m5.large 등은 초과해 제외).
      instance_types = ["t3.medium", "t3a.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      desired_size   = 1
      # 비용 예외 항목(루트 CLAUDE.md 참조) — 실습 환경 한정으로 SPOT 중단 시 Karpenter
      # 자가 회복 능력 상실 리스크를 감수한다. production은 ON_DEMAND 유지.
      capacity_type = "SPOT"
    }

    # dev: t3.medium 시스템 노드 pod 한계(17)에서 시스템 애드온 슬롯을 확보하기 위해
    # CoreDNS·EBS CSI Controller·cert-manager를 1 replica로 축소한다.
    # 재시작 시 수초 단절 허용 — dev 환경 비용 예외 (production은 기본값 2 유지).
    coredns_configuration_values = jsonencode({ replicaCount = 1 })
    ebs_csi_configuration_values = jsonencode({ controller = { replicaCount = 1 } })
    # cert-manager: replicaCount=1(controller·webhook·cainjector), CriticalAddonsOnly toleration으로 시스템 노드 배치
    cert_manager_configuration_values = jsonencode({
      replicaCount = 1
      tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
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
    # EKS 1.34 표준 지원 종료: 2026-12-02. 이전에 1.35로 업그레이드하거나 자동 업그레이드 허용.
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
      principal_arn = "arn:aws:iam::${var.account_id_mgmt}:user/study"
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # Terraform 실행 주체(AWS SSO Role)에게 K8s ClusterAdmin 부여.
    # helm/kubernetes provider가 aws eks get-token --profile terraform으로 이 Role의 토큰을 발급받는다.
    # principal_arn은 data.aws_iam_session_context.current.issuer_arn으로 동적 참조 — SSO Role ARN 변경에 자동 대응.
    terraform_execution = {
      principal_arn = data.aws_iam_session_context.current.issuer_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
