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
  region  = "ap-northeast-2"
  profile = "terraform-workload"
  # Organizations 정책 report_required_tag_for 리소스 타입에서 태그 키 누락 시 plan 차단.
  tag_policy_compliance = "error"
  default_tags {
    tags = local.common_tags
  }
}

# GitOps Bridge 레지스트리 — Hub(monitoring, 157325288431) 계정의 SSM Parameter Store에
# 이 클러스터의 spoke 등록 정보를 쓰기 위한 크로스 계정 provider(gitops-bridge-registry.tf).
#
# [WHY assume_role — 이 프로젝트의 일반 규칙(docs/terraform-principles.md: provider
# assume_role 블록 미사용, SSO 프로필이 AdministratorAccess 직접 제공)의 예외]
# base credentials는 production 자신의 프로필(terraform-workload)을 쓰고, monitoring에
# 미리 만들어둔 범위가 좁은 Role(gitops-bridge-registry.tf의
# aws_iam_role.gitops_bridge_registry_writer — ssm:PutParameter를 이 계정 경로로만
# 스코프)을 assume_role로 넘겨받는다 — monitoring의 관리자 프로필을 그대로 쓰면 이
# root(production)가 monitoring 계정 전체에 대한 admin 권한을 갖게 되어 최소 권한
# 원칙에 위배되기 때문이다(develop의 동일 provider와 완전히 같은 이유).
provider "aws" {
  alias   = "gitops_bridge_registry"
  region  = "ap-northeast-2"
  profile = "terraform-workload"

  assume_role {
    role_arn     = local.gitops_bridge_registry_writer_role_arn
    session_name = "gitops-bridge-registry-write-production"
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
        "--profile", "terraform-workload",
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
      "--profile", "terraform-workload",
    ]
  }
}
