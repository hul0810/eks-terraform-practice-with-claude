locals {
  environment = "monitoring"
  project     = "eks-practice"

  environment_short = "mon"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids

  # cert-manager의 controller·webhook·cainjector 3개 컴포넌트가 공유하는 배치 규칙.
  # 시스템 노드 그룹(modules/eks)의 role=system 레이블을 겨냥한다 — CriticalAddonsOnly
  # toleration은 "이 노드에 떠도 된다"는 허가일 뿐이라 taint가 없는 Karpenter NodePool로 새는 것을
  # 막지 못한다. 배치를 확정하려면 이 강제가 함께 있어야 Karpenter와 Cluster Autoscaler가 같은
  # Pending Pod에 동시에 반응하지 않는다. 상세: docs/addon-strategy.md → 오토스케일러 이원화와 노드 배치 규칙
  #
  # affinity는 통째로 교체되는 필드라 애드온 기본값(os/arch/compute-type 제약)을 그대로 옮겨 적은 뒤
  # role=system만 더한다 — 같은 matchExpressions 안에 넣어야 AND로 평가된다(별도 nodeSelectorTerm은 OR).
  cert_manager_affinity = {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] },
            { key = "eks.amazonaws.com/compute-type", operator = "NotIn", values = ["hybrid"] },
            { key = "role", operator = "In", values = ["system"] },
          ]
        }]
      }
    }
  }

  eks = {
    cluster_name       = "${local.project}${local.name_suffix}"
    kubernetes_version = "1.34"

    addon_versions = {
      # 버전 조회: aws eks describe-addon-versions --kubernetes-version 1.34 --region ap-northeast-2
      # 2026-06-24 기준 default 버전
      vpc_cni                = "v1.21.2-eksbuild.2"
      kube_proxy             = "v1.34.6-eksbuild.11"
      coredns                = "v1.12.4-eksbuild.17"
      eks_pod_identity_agent = "v1.3.10-eksbuild.3"
      ebs_csi_driver         = "v1.62.0-eksbuild.1"
      cert_manager           = "v1.20.2-eksbuild.3"
      # cert-manager: OTel Operator의 admission webhook 인증서 발급에 필요
    }

    # monitoring: 로컬 PC에서 kubectl 직접 접근 및 observability 스택 배포 편의를 위해 public 허용
    endpoint_public_access = true
    public_access_cidrs    = [var.operator_ip_cidr]

    enabled_log_types = []

    system_node = {
      # t3a.medium(AMD)을 추가해 Spot 풀을 다양화한다 — t3(Intel)와 물리적으로 다른 용량
      # 풀이라 동시 회수 상관관계가 낮다. 두 타입 모두 2vCPU/4GiB 동일 스펙(파드 한도 유지)이며,
      # 온디맨드 가격이 t3.medium($0.0520/hr, ap-northeast-2) 이하인 것만 선택했다
      # (t3a.medium $0.0468/hr — 2026-07-08 조회. t2.medium/c5.large/m5.large 등은 초과해 제외).
      instance_types = ["t3.medium", "t3a.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 3
      # monitoring 환경도 비용 절감: min/desired=1 (HA 비활성화 의도적 예외 — CLAUDE.md 참조)
      desired_size = 1
      # 비용 예외 항목(루트 CLAUDE.md 참조) — 실습 환경 한정으로 SPOT 중단 시 Karpenter
      # 자가 회복 능력 상실 리스크를 감수한다. production은 ON_DEMAND 유지.
      capacity_type = "SPOT"
    }

    # Prefix Delegation: ENI 슬롯 1개당 /28(IP 16개)을 할당해 노드당 pod 상한을 높인다.
    # t3.medium 기준 17 → 이론값 242(MNG 상한 110). 추가 비용 없음.
    # WARM_PREFIX_TARGET은 선언하지 않는다 — 애드온 기본값이 이미 AWS 권장값(1)이므로
    # 같은 값을 고정하면 향후 권장값이 바뀌어도 따라가지 못한다.
    vpc_cni_configuration_values = jsonencode({
      env = {
        ENABLE_PREFIX_DELEGATION = "true"
      }
    })

    # monitoring: dev와 동일하게 시스템 노드 슬롯 절약
    #
    # affinity는 통째로 교체되는 필드다. 애드온 기본값(os/arch 제약, replica 분산 podAntiAffinity)을
    # 그대로 옮겨 적은 뒤 role=system만 더한다 — role을 별도 nodeSelectorTerm으로 두면 term끼리
    # OR로 평가되어 제약이 오히려 느슨해지므로 같은 matchExpressions 안에 넣는다.
    coredns_configuration_values = jsonencode({
      replicaCount = 1
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [
                { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
                { key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] },
                { key = "role", operator = "In", values = ["system"] },
              ]
            }]
          }
        }
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchExpressions = [{ key = "k8s-app", operator = "In", values = ["kube-dns"] }]
              }
              topologyKey = "kubernetes.io/hostname"
            }
          }]
        }
      }
    })
    # 기본값에는 required nodeAffinity가 없다 — preferred 규칙과 podAntiAffinity를 그대로 옮기고
    # role=system required를 새로 더한다.
    ebs_csi_configuration_values = jsonencode({
      controller = {
        replicaCount = 1
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [{ key = "role", operator = "In", values = ["system"] }]
              }]
            }
            preferredDuringSchedulingIgnoredDuringExecution = [{
              weight = 1
              preference = {
                matchExpressions = [{
                  key      = "eks.amazonaws.com/compute-type"
                  operator = "NotIn"
                  values   = ["fargate", "auto", "hybrid"]
                }]
              }
            }]
          }
          podAntiAffinity = {
            preferredDuringSchedulingIgnoredDuringExecution = [{
              weight = 100
              podAffinityTerm = {
                labelSelector = {
                  matchExpressions = [{ key = "app", operator = "In", values = ["ebs-csi-controller"] }]
                }
                topologyKey = "kubernetes.io/hostname"
              }
            }]
          }
        }
      }
    })
    # cert-manager: 3개 컴포넌트(controller·webhook·cainjector)가 동일한 배치 규칙을 쓴다.
    cert_manager_configuration_values = jsonencode({
      replicaCount = 1
      tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
      affinity     = local.cert_manager_affinity
      webhook = {
        replicaCount = 1
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
        affinity     = local.cert_manager_affinity
      }
      cainjector = {
        replicaCount = 1
        tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }]
        affinity     = local.cert_manager_affinity
      }
    })

    upgrade_policy = { support_type = "STANDARD" }

    node_security_group_tags = {
      "karpenter.sh/discovery" = "${local.project}${local.name_suffix}"
    }

    # gp3 기본 StorageClass 생성(modules/eks/1.0.0/storage-class.tf) — LGTM 스택 등
    # storageClassName을 생략하는 차트를 위해 필요. providers.tf에 kubernetes provider 이미 구성됨.
    enable_default_storage_class = true
  }

  access_entries = {
    study = {
      principal_arn = "arn:aws:iam::${var.account_id_mgmt}:user/study"
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    terraform_execution = {
      principal_arn = data.aws_iam_session_context.current.issuer_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
