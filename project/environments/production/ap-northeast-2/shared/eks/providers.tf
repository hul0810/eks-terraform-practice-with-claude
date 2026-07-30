terraform {
  required_version = "~> 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    # terraform-aws-modules/eks v21.x 가 OIDC Provider 지문 계산에 내부적으로 사용
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # terraform-aws-modules/eks v21.x 가 일부 리소스 타이밍 제어에 내부적으로 사용
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    # enable_default_storage_class = true (locals.tf) — gp3 기본 StorageClass 생성에 사용
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform-workload"
  # Organizations 정책 report_required_tag_for 리소스 타입에서 태그 키 누락 시 plan 차단.
  # 태그 값 유효성 검사는 main.tf의 validate_tags precondition이 담당.
  tag_policy_compliance = "error"
  default_tags {
    tags = local.common_tags
  }
}

# monitoring NAT Gateway 공인 IP를 읽기 전용으로 조회하기 위한 provider(data.tf 참고).
# 읽기 전용이라 admin SSO 프로필을 그대로 swap한다 — eks-addons/providers.tf의
# aws.gitops_bridge_registry(쓰기, scoped assume_role)와 다른 이유는 그 주석 참고.
provider "aws" {
  alias   = "monitoring"
  region  = "ap-northeast-2"
  profile = "terraform-monitoring"
}

# 이 root가 클러스터 생성 주체라 data.aws_eks_cluster 대신 module.eks 출력에서
# endpoint/CA를 받는다(monitoring eks/providers.tf와 동일 근거). enable_default_storage_class를
# 켰기 때문에(locals.tf) kubernetes provider가 필요하다.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", local.eks.cluster_name,
      "--region", "ap-northeast-2",
      "--profile", "terraform-workload",
    ]
  }
}
