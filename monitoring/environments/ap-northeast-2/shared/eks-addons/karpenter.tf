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
      template = merge(
        {
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
                  # 조직 SCP(DenyOtherInstance, p-v2sbnmua)가 nano~xlarge 크기만 RunInstances를 허용한다.
                  # metal/2xlarge 이상을 배제하지 않으면 Karpenter의 권한 검증(auth check)이나
                  # 실제 노드 프로비저닝이 SCP에 막혀 "unauthorized to call ec2:RunInstances"로 실패한다.
                  key      = "karpenter.k8s.aws/instance-size"
                  operator = "In"
                  values   = ["nano", "micro", "small", "medium", "large", "xlarge"]
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
        },
        # 유상태 풀만 라벨을 부여한다. taint는 무상태 워크로드를 "밀어내기"만 하므로,
        # 유상태 파드가 이 풀이 만든 노드를 nodeSelector로 명시 선택하게 하려면 라벨이 필요하다.
        length(each.value.labels) > 0 ? { metadata = { labels = each.value.labels } } : {}
      )

      weight = each.value.weight

      # 풀별 disruption 정책 — general은 기존 공격적인 컨솔리데이션 유지,
      # observability-stateful은 locals.tf 주석 참조 (PVC 재연결 지연 방지를 위해 완화)
      disruption = {
        consolidationPolicy = each.value.consolidation_policy
        consolidateAfter    = each.value.consolidate_after
        budgets             = each.value.disruption_budgets
      }

      limits = each.value.limits
    }
  }

  computed_fields = [
    # general 풀은 metadata를 선언하지 않으므로(labels={}) 이 경로 전체를 computed로 유지해야
    # 서버 측 기본값 처리와 무관하게 drift가 발생하지 않는다. observability-stateful의 labels는
    # computed 여부와 무관하게 최초 apply 시 선언값이 그대로 적용된다 (dev/production과 동일 패턴).
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
