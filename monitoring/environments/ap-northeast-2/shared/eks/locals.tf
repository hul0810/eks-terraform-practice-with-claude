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

  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids

  eks = {
    cluster_name       = "${local.project}${local.name_suffix}"
    kubernetes_version = "1.34"

    addon_versions = {
      # 버전 조회: aws eks describe-addon-versions --kubernetes-version 1.34 --region ap-northeast-2
      # 2026-06-24 기준 default 버전
      vpc_cni                  = "v1.21.2-eksbuild.2"
      kube_proxy               = "v1.34.6-eksbuild.11"
      coredns                  = "v1.12.4-eksbuild.17"
      eks_pod_identity_agent   = "v1.3.10-eksbuild.3"
      ebs_csi_driver           = "v1.62.0-eksbuild.1"
      secrets_store_csi_driver = "v3.1.1-eksbuild.1"
      cert_manager             = "v1.20.2-eksbuild.3"
      # cert-manager: OTel Operator의 admission webhook 인증서 발급에 필요
    }

    # monitoring: 로컬 PC에서 kubectl 직접 접근 및 observability 스택 배포 편의를 위해 public 허용
    endpoint_public_access = true
    public_access_cidrs    = ["OPERATOR_IP/32"]

    enabled_log_types = []

    system_node = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      # monitoring 환경도 비용 절감: min/desired=1 (HA 비활성화 의도적 예외 — CLAUDE.md 참조)
      desired_size = 1
    }

    # monitoring: dev와 동일하게 시스템 노드 슬롯 절약
    coredns_configuration_values = jsonencode({ replicaCount = 1 })
    ebs_csi_configuration_values = jsonencode({ controller = { replicaCount = 1 } })
    cert_manager_configuration_values = jsonencode({
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

    upgrade_policy = { support_type = "STANDARD" }

    node_security_group_tags = {
      "karpenter.sh/discovery" = "${local.project}${local.name_suffix}"
    }
  }

  access_entries = {
    study = {
      principal_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:user/study"
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
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
