terraform {
  required_version = "~> 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
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

# eks-addons(다른 monitoring 루트)는 data.aws_eks_cluster로 exec 인증을 구성하지만,
# 이 루트는 클러스터를 직접 생성하는 주체라 최초 apply 시점에는 그 데이터소스가 조회할
# 클러스터 자체가 아직 없다 — module.eks의 출력(endpoint/CA)에서 직접 받는다.
# cluster_name은 local.eks.cluster_name(정적 값)이라 이 exec 토큰 생성은 module 출력의
# 생성 여부와 무관하게 항상 유효하다.
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
      "--profile", "terraform-monitoring",
    ]
  }
}
