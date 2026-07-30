terraform {
  required_version = "~> 1.9"
  required_providers {
    # aws_iam_role(vpc_cni, ebs_csi) Pod Identity Role 생성에 사용.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46"
    }
    # kubernetes_storage_class_v1.gp3(storage-class.tf, enable_default_storage_class=true일 때만) 생성에 사용.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }
}
