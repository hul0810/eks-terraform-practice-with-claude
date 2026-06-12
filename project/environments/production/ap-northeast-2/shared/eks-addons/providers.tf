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
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform"
  assume_role {
    role_arn = "arn:aws:iam::891396992584:role/TerraformExecutionRole"
  }
  # Organizations 정책 report_required_tag_for 리소스 타입에서 태그 키 누락 시 plan 차단.
  tag_policy_compliance = "error"
  default_tags {
    tags = local.common_tags
  }
}

# helm/kubernetes provider는 data "aws_eks_cluster"로 클러스터 정보를 가져온다.
# Terraform 제약: provider 설정에서 module output이나 locals를 참조할 수 없어
# data source를 별도로 사용한다. eks/ state가 먼저 apply된 상태에서만 동작한다.
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
        "--profile", "terraform",
        # AWS provider의 assume_role은 exec 블록에 자동 전파되지 않으므로 명시적으로 지정한다
        "--role-arn", "arn:aws:iam::891396992584:role/TerraformExecutionRole",
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
      "--profile", "terraform",
      # AWS provider의 assume_role은 exec 블록에 자동 전파되지 않으므로 명시적으로 지정한다
      "--role-arn", "arn:aws:iam::891396992584:role/TerraformExecutionRole",
    ]
  }
}
