################################################################################
# Karpenter EC2NodeClass & NodePool
#
# ⚠️ 2단계 apply 필수 (첫 배포 또는 Karpenter 재설치 시)
#
#   hashicorp/kubernetes provider의 kubernetes_manifest는 plan 단계에서
#   클러스터 API에 CRD 스키마를 조회하여 manifest를 검증한다.
#   depends_on은 apply 실행 순서만 제어하며 plan-time 검증에는 영향을 주지 않는다.
#   Karpenter CRD가 없는 상태에서 plan을 실행하면 "no matches for kind EC2NodeClass" 에러가 발생한다.
#
#   1단계: terraform apply -target=module.eks_addons
#          → Karpenter Helm chart 설치 → CRD 클러스터 등록
#   2단계: terraform apply
#          → EC2NodeClass / NodePool 생성
#
# computed_fields 설정 이유:
#   Karpenter webhook과 컨트롤러는 일부 필드를 서버사이드에서 자동으로 채운다.
#   이 필드들을 computed_fields로 선언하지 않으면 terraform plan이 drift로 감지하여
#   매 plan마다 불필요한 update를 생성한다.
#
# field_manager.force_conflicts 이유:
#   Karpenter webhook이 일부 필드를 소유(field management)하므로
#   충돌 없이 apply할 수 있도록 force_conflicts = true를 설정한다.
################################################################################

# ── EC2NodeClass ─────────────────────────────────────────────────────────────
# Karpenter가 노드를 프로비저닝할 때 사용할 EC2 설정을 정의한다.
# 단일 EC2NodeClass를 모든 NodePool이 공유한다.
# 서브넷·SG가 NodePool별로 달라야 하는 경우에만 복수 EC2NodeClass를 생성한다.
resource "kubernetes_manifest" "karpenter_ec2_node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"

    metadata = {
      name = "default"
    }

    spec = {
      # Karpenter v1 API(karpenter.k8s.aws/v1)에서 amiFamily는 deprecated.
      # amiSelectorTerms.alias로 AMI 패밀리를 지정한다. (required, minItems: 1)
      # "al2023@latest": 클러스터 버전에 맞는 최신 AL2023 AMI를 자동 선택.
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      # blueprints가 생성한 노드 IAM Role 이름.
      # 이 Role을 가진 EC2 인스턴스만 클러스터에 노드로 조인할 수 있다.
      role = module.eks_addons.karpenter_node_iam_role_name

      # karpenter.sh/discovery 태그로 프라이빗 서브넷을 자동 탐색한다.
      # modules/vpc의 private_subnet_tags에 동일한 값이 부여되어 있어야 한다.
      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]

      # karpenter.sh/discovery 태그로 node SG를 자동 탐색한다.
      # modules/eks의 node_security_group_tags에 동일한 값이 부여되어 있어야 한다.
      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = local.cluster_name
          }
        }
      ]
    }
  }

  # Karpenter webhook이 status, spec.kubelet 등을 서버사이드에서 자동으로 채운다.
  # amiSelectorTerms는 사용자가 선언하므로 computed_fields에서 제외한다.
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

# ── NodePool ─────────────────────────────────────────────────────────────────
# 분리 기준과 각 NodePool의 역할은 locals.tf의 karpenter_node_pools 정의를 참조한다.
#
# for_each 사용 이유:
#   NodePool 추가/제거를 locals.tf 항목 변경만으로 처리하기 위해 for_each를 사용한다.
#   새 NodePool 추가 시 karpenter.tf 수정 없이 locals.tf에 항목만 추가하면 된다.
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
                # Gt operator는 단일 숫자 문자열을 요구한다 — tostring으로 타입을 명시적으로 보장
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
          # Taint가 있는 NodePool만 taints 블록을 포함한다.
          # 빈 리스트로 선언하면 Karpenter webhook이 drift로 감지하므로 조건부 merge로 처리한다.
          length(each.value.taints) > 0 ? { taints = each.value.taints } : {}
        )
      }

      # 동일 Pod가 여러 NodePool에 스케줄 가능할 때 우선순위 (높을수록 우선)
      weight = each.value.weight

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        # develop: 30초. production은 300초 이상 권장.
        # 이유: 스파이크 트래픽 직후 30초 내 노드 회수 → 재증가 시 프로비저닝 대기 발생.
        consolidateAfter = "30s"
        # 동시 통합 상한: 전체 노드의 20%까지만 동시에 드레인 허용.
        # 미설정 시 다수 노드가 동시 드레인되어 PDB 없는 워크로드가 일제히 종료될 수 있다.
        budgets = [{ nodes = "20%" }]
      }

      limits = each.value.limits
    }
  }

  computed_fields = [
    "spec.template.metadata",
    # Karpenter 컨트롤러가 kubeletConfiguration을 서버사이드에서 자동 설정한다.
    # computed 미선언 시 매 plan마다 불필요한 update diff가 발생한다.
    "spec.template.spec.kubeletConfiguration",
    "metadata.annotations",
    "metadata.labels",
    "status",
  ]

  field_manager {
    force_conflicts = true
  }

  # EC2NodeClass가 클러스터에 먼저 생성되어야 Karpenter webhook이 NodePool의 nodeClassRef를 검증할 수 있다.
  depends_on = [
    module.eks_addons,
    kubernetes_manifest.karpenter_ec2_node_class,
  ]
}

# ── EC2NodeClass finalizer 제거 (destroy 순서 보장) ──────────────────────────
#
# 문제: terraform destroy 시 EC2NodeClass가 수 분간 블로킹되는 현상
#
# 원인:
#   EC2NodeClass에는 "karpenter.k8s.aws/termination" finalizer가 있다.
#   Karpenter 컨트롤러가 이 finalizer를 제거해야만 Kubernetes가 오브젝트를 삭제한다.
#   finalizer 제거 전에 Karpenter는 연결된 IAM Instance Profile 등 AWS 리소스를 정리한다.
#   이 정리 작업에는 IRSA(IAM Role)를 통한 AWS API 인증이 필요하다.
#
#   그런데 terraform destroy는 kubernetes_manifest와 module.eks_addons를 병렬로 삭제한다.
#   module.eks_addons 내부에서 Karpenter IRSA Role이 먼저 삭제되면,
#   Karpenter가 AWS API를 인증할 수 없어 finalizer를 제거하지 못하고 무한 재시도에 빠진다.
#
# 해결:
#   null_resource에 depends_on = [kubernetes_manifest.karpenter_ec2_node_class]를 설정한다.
#   Terraform은 destroy 시 depends_on의 역순으로 삭제하므로,
#   null_resource가 먼저 삭제되면서 destroy provisioner가 실행된다.
#   provisioner가 finalizer를 강제 제거하면 이후 kubernetes_manifest 삭제가 즉시 완료된다.
#   그 다음 module.eks_addons(IRSA Role 등)가 삭제되므로 인증 문제도 발생하지 않는다.
#
# destroy 순서:
#   1. null_resource destroy → kubectl patch로 finalizer 제거
#   2. kubernetes_manifest.karpenter_ec2_node_class destroy → finalizer 없으므로 즉시 삭제
#   3. module.eks_addons destroy → IRSA Role, SQS, Helm chart 등 AWS 리소스 삭제
#
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
    # module.eks_addons를 포함해야 destroy 시 null_resource가 module.eks_addons보다 먼저 삭제된다.
    # 미포함 시 Terraform이 null_resource와 module.eks_addons를 병렬로 삭제하고,
    # IRSA Role이 먼저 사라지면 kubectl patch가 성공하더라도 Karpenter가 finalizer를 재추가할 수 있다.
    module.eks_addons,
  ]
}
