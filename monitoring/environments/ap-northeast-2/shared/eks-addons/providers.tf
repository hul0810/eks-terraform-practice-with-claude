terraform {
  required_version = "~> 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region                = "ap-northeast-2"
  profile               = "terraform-monitoring"
  tag_policy_compliance = "error"
  default_tags {
    tags = local.common_tags
  }
}

# GitOps Bridge Hub-Spoke(Phase 6-5): dev/prd 클러스터(workload 계정, 657231015203)의
# EKS API 엔드포인트·CA 인증서를 읽어 cluster Secret에 채우기 위한 크로스 계정 provider.
# terraform_remote_state로 workload 계정의 S3 state 버킷을 읽으려면 버킷 정책에 크로스
# 계정 read 권한이 별도로 필요한데, 로컬 AWS CLI 프로필(terraform-workload)이 이미
# 세션 전역에 구성돼 있어 그걸 그대로 provider alias로 재사용하는 게 더 간단하다 —
# state 버킷 정책을 건드릴 필요가 없다.
provider "aws" {
  alias   = "workload"
  region  = "ap-northeast-2"
  profile = "terraform-workload"
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", local.cluster_name,
        "--region", "ap-northeast-2",
        "--profile", "terraform-monitoring",
      ]
    }
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", local.cluster_name,
      "--region", "ap-northeast-2",
      "--profile", "terraform-monitoring",
    ]
  }
}
