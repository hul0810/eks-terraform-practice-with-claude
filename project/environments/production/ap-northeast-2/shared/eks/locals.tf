locals {
  environment = "production"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  # production은 environment_short를 빈 문자열로 두어 구분자까지 완전히 제거한다.
  environment_short = ""
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
      vpc_cni                  = "v1.21.2-eksbuild.2"
      kube_proxy               = "v1.34.6-eksbuild.11"
      coredns                  = "v1.12.4-eksbuild.17"
      eks_pod_identity_agent   = "v1.3.10-eksbuild.3"
      ebs_csi_driver           = "v1.62.0-eksbuild.1"
      secrets_store_csi_driver = "v3.1.1-eksbuild.1"
      cert_manager             = "v1.20.2-eksbuild.3"
    }

    # cert-manager: CriticalAddonsOnly toleration으로 시스템 노드 배치. replica는 기본값(2) 유지
    cert_manager_configuration_values = jsonencode({
      tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      webhook = {
        tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      }
      cainjector = {
        tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      }
    })

    # production: Bastion/VPN 미구축 결정(비용 부담)에 따라 특정 공인 IP만 허용하는 퍼블릭 엔드포인트로 전환.
    # endpoint_private_access는 모듈에서 항상 true로 고정되어 VPC 내부(노드 ↔ 컨트롤 플레인) 트래픽은 여전히 private 경로를 사용한다.
    endpoint_public_access = true

    # 공인 IP 변경 시 갱신 후 terraform apply 필요. 0.0.0.0/0 등 광범위한 CIDR로 변경 금지.
    endpoint_public_access_cidrs = ["OPERATOR_IP/32"]

    # 컨트롤 플레인 로그: CloudWatch Logs 비용 발생 (로그 타입당 약 $0.50/GB~)
    # 기본 비활성화. 디버깅 필요 시 원하는 타입 추가 후 terraform apply.
    # 가능한 값: "api", "audit", "authenticator", "controllerManager", "scheduler"
    enabled_log_types = []

    system_node = {
      instance_types = ["t3.medium"] # 전체 인스턴스 유형 통틀어 최저가(x86) — 모듈 변수 설명상 최소 권장 사양
      ami_type       = "AL2023_x86_64_STANDARD"
      # 비용 우선: 시스템 노드 1개 운영 (HA 정책 예외 — CLAUDE.md 비용 예외 항목 참조)
      # HA 복원 시: min_size = 2, desired_size = 2 로 변경 (시스템 노드 2개 상시 운영)
      min_size     = 1
      max_size     = 4
      desired_size = 1
    }

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
      principal_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:user/study"
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
