locals {
  environment = "develop"
  project     = "eks-practice"

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids

  eks = {
    cluster_name       = "${local.project}-${local.environment}"
    kubernetes_version = "1.33"

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
  }

  # EKS 클러스터 접근 주체 목록
  # 클러스터가 재생성되어도 접근 권한이 자동 복원되도록 Terraform으로 관리한다.
  # principal_arn: IAM User 또는 Role ARN
  # policy_arn: AmazonEKSClusterAdminPolicy (클러스터 전체 admin)
  #             AmazonEKSEditPolicy (네임스페이스 수준 편집)
  #             AmazonEKSViewPolicy (읽기 전용)
  access_entries = {
    study = {
      principal_arn = "arn:aws:iam::891396992584:user/study"
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    }
  }
}
