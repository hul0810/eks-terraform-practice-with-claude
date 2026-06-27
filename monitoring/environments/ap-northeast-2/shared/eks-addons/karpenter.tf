################################################################################
# Karpenter EC2NodeClass & NodePool
#
# ⚠️ 2단계 apply 필수 (첫 배포 또는 Karpenter 재설치 시)
#
#   1단계: terraform apply -target=module.eks_addons
#          → Karpenter Helm chart 설치 → CRD 클러스터 등록
#   2단계: terraform apply
#          → EC2NodeClass / NodePool 생성
#
# 설계 결정 및 주의사항은 dev 환경의 karpenter.tf 주석을 참조한다.
################################################################################

resource "kubernetes_manifest" "karpenter_ec2_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"

    metadata = {
      name = "default"
    }

    spec = {
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      role = module.eks_addons.karpenter_node_iam_role_name

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      tags = {
        Name = "${local.cluster_name}-karpenter"
      }
    }
  }

  computed_fields = [
    "spec.kubelet",
    "metadata.annotations",
    "metadata.labels",
    "status",
  ]

  field_manager {
    force_conflicts = true
  }

  depends_on = [module.eks_addons]
}

resource "kubernetes_manifest" "karpenter_node_pool" {
  for_each = local.karpenter_node_pools

  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"

    metadata = {
      name = each.key
    }

    spec = {
      template = {
        spec = merge(
          {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "default"
            }

            requirements = [
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = each.value.capacity_types
              },
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = each.value.instance_families
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "Gt"
                values   = [tostring(each.value.instance_gen_min)]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = each.value.architectures
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
            ]
          },
          length(each.value.taints) > 0 ? { taints = each.value.taints } : {}
        )
      }

      weight = each.value.weight

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
        budgets             = [{ nodes = "20%" }]
      }

      limits = each.value.limits
    }
  }

  computed_fields = [
    "spec.template.metadata",
    "spec.template.spec.kubeletConfiguration",
    "metadata.annotations",
    "metadata.labels",
    "status",
  ]

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    module.eks_addons,
    kubernetes_manifest.karpenter_ec2_node_class,
  ]
}

resource "null_resource" "karpenter_nodeclass_finalizer_remover" {
  triggers = {
    nodeclass_name = kubernetes_manifest.karpenter_ec2_node_class.manifest.metadata.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl patch ec2nodeclass ${self.triggers.nodeclass_name} --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' || true"
  }

  depends_on = [
    kubernetes_manifest.karpenter_ec2_node_class,
    module.eks_addons,
  ]
}

resource "null_resource" "karpenter_nodeclaims_drainer" {
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete nodeclaims --all --timeout=180s || true"
  }

  depends_on = [
    kubernetes_manifest.karpenter_node_pool,
    module.eks_addons,
  ]
}
