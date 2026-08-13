locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리하여
  # "{cluster_name}-karpenter-controller-irsa" 등 긴 접미사가 붙는 IAM 리소스 이름,
  # ALB 이름 32자 제한 등에서 여유를 확보한다. 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
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
    }

    # develop: 로컬 PC에서 kubectl 직접 접근 편의를 위해 public 엔드포인트 허용
    # production: false로 변경 후 VPN/Bastion 경유
    endpoint_public_access = true

    # 로컬 kubectl 접근을 허용할 IP 목록. 두 번째 IP는 monitoring의 ArgoCD Hub가 이 클러스터의
    # EKS API에 접근하기 위한 monitoring NAT Gateway 공인 IP다 — VPC Peering(mon-to-dev,
    # docs/network-design.md)이 이미 연결돼 있어도 EKS 관리형 private hosted zone은 피어링된
    # VPC에 자동 연결되지 않아 Hub→spoke 트래픽은 여전히 public 엔드포인트를 탄다.
    # NAT Gateway는 EIP를 고정하지 않아 monitoring teardown→재provision마다 IP가 바뀌므로
    # data.aws_nat_gateway.monitoring(data.tf)으로 매 plan/apply 시점에 동적으로 읽는다.
    public_access_cidrs = [var.operator_ip_cidr, "${data.aws_nat_gateway.monitoring.public_ip}/32"]

    # 컨트롤 플레인 로그: CloudWatch Logs 비용 발생 (로그 타입당 약 $0.50/GB~)
    # 기본 비활성화. 디버깅 필요 시 원하는 타입 추가 후 terraform apply.
    # 가능한 값: "api", "audit", "authenticator", "controllerManager", "scheduler"
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
      desired_size   = 1
      # 비용 예외 항목(루트 CLAUDE.md 참조) — 실습 환경 한정으로 SPOT 중단 시 Karpenter
      # 자가 회복 능력 상실 리스크를 감수한다. production은 ON_DEMAND 유지.
      capacity_type = "SPOT"
    }

    # Prefix Delegation: ENI 슬롯 1개당 /28(IP 16개)을 할당해 노드당 pod 상한을 높인다.
    # t3.medium 기준 17 → 이론값 242(MNG 상한 110). 추가 비용 없음.
    # WARM_PREFIX_TARGET은 선언하지 않는다 — 애드온 기본값이 이미 AWS 권장값(1)이므로
    # 같은 값을 고정하면 향후 권장값이 바뀌어도 따라가지 못한다.
    # Security Groups for Pods(SGP): Pod마다 브랜치 ENI를 붙여 Pod 단위 SG를 적용한다.
    # ENABLE_POD_ENI를 켜면 modules/eks가 클러스터 IAM Role에 AmazonEKSVPCResourceController를
    # 자동으로 붙인다(그 값 하나에서 파생 — modules/eks/1.0.0/main.tf 상단 local 참조).
    #
    # strict 모드를 쓰는 이유: Pod SG가 ingress·egress를 온전히 통제하는 것이 SGP의 본래 취지이고,
    # standard는 VPC 밖으로 나가는 트래픽이 노드 IP로 SNAT되어 Pod 단위 egress 통제가 불가능하다.
    # 대신 strict는 DISABLE_TCP_EARLY_DEMUX를 반드시 동반한다 — 없으면 kubelet이 브랜치 ENI 위의
    # Pod에 TCP로 붙지 못해 probe가 전부 실패하고, 그 증상이 런타임에서만 드러난다.
    #
    # AWS_VPC_K8S_CNI_EXTERNALSNAT은 켜지 않는다. Best Practices가 이 설정을 요구하는 전제는
    # "인터넷 접근이 필요한 SGP Pod"인데, 이 프로젝트의 Pod SG는 0.0.0.0/0 egress를 두지 않아
    # 그 전제에 해당하지 않는다. 반면 이 설정은 SGP Pod뿐 아니라 클러스터 전체 Pod의 egress
    # 경로를 바꾸므로(피어링 건너편에 노드 IP 대신 Pod IP가 노출되는 등) 얻는 것 없이 영향
    # 범위만 넓어진다. SGP Pod에 인터넷 egress를 열어야 할 때 함께 검토한다.
    # 상세: docs/security-groups-for-pods.md
    # enforcing mode는 standard를 쓴다. EKS Pod Identity가 링크로컬 주소로 자격증명을 제공하는데
    # strict는 모든 아웃바운드를 브랜치 ENI로 몰아 VPC로 내보내므로 그 주소에 도달할 수 없고,
    # SG 규칙으로도 열 수 없다(경로 자체가 없다). order가 SQS 발행에 Pod Identity를 쓰므로
    # strict를 유지하면 SGP를 그 워크로드로 확장하는 순간 자격증명이 끊긴다.
    # standard에서도 브랜치 ENI와 Pod 단위 접근 통제는 그대로다 —
    # 포기하는 것은 "VPC 밖 egress를 Pod 단위로 막는 것"뿐이다.
    # DISABLE_TCP_EARLY_DEMUX는 strict 전용 요구사항이라 두지 않는다(standard는 노드 SG가
    # 함께 적용되어 kubelet probe가 정상 동작한다).
    # 상세: docs/security-groups-for-pods.md
    vpc_cni_configuration_values = jsonencode({
      env = {
        ENABLE_PREFIX_DELEGATION          = "true"
        ENABLE_POD_ENI                    = "true"
        POD_SECURITY_GROUP_ENFORCING_MODE = "standard"
      }
    })

    # dev: t3.medium 시스템 노드의 CPU·메모리(2 vCPU/4 GiB)를 시스템 애드온이 잠식하지
    # 않도록 CoreDNS·EBS CSI Controller·cert-manager를 1 replica로 축소한다.
    # 재시작 시 수초 단절 허용 — dev 환경 비용 예외 (production은 기본값 2 유지).
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
    # cert-manager: replicaCount=1(controller·webhook·cainjector), CriticalAddonsOnly toleration +
    # role=system nodeAffinity로 시스템 노드에 고정. 3개 컴포넌트가 동일한 배치 규칙을 쓴다.
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

    # STANDARD: 표준 지원 종료 시 다음 버전으로 자동 업그레이드 — Extended Support 비용($0.60/hr) 차단
    # EKS 1.34 표준 지원 종료: 2026-12-02. 이전에 1.35로 업그레이드하거나 자동 업그레이드 허용.
    upgrade_policy = { support_type = "STANDARD" }

    # Karpenter EC2NodeClass가 karpenter.sh/discovery 태그로 node SG를 자동 탐색한다.
    # 값은 EC2NodeClass의 securityGroupSelectorTerms와 일치해야 한다.
    node_security_group_tags = {
      "karpenter.sh/discovery" = "${local.project}${local.name_suffix}"
    }

    # gp3 기본 StorageClass 생성(modules/eks/1.0.0/storage-class.tf) — providers.tf에
    # kubernetes provider 구성 필요(이 옵션이 그 이유).
    enable_default_storage_class = true
  }

  # EKS 클러스터 접근 주체 목록
  # 클러스터가 재생성되어도 접근 권한이 자동 복원되도록 Terraform으로 관리한다.
  # principal_arn: IAM User 또는 Role ARN
  # policy_associations: principal당 여러 정책을 map으로 선언 가능
  #   policy_arn: AmazonEKSClusterAdminPolicy (클러스터 전체 admin)
  #               AmazonEKSEditPolicy (네임스페이스 수준 편집)
  #               AmazonEKSViewPolicy (읽기 전용)
  # access_scope.type: "cluster" (전체) 또는 "namespace" (특정 네임스페이스)
  # access_scope.namespaces: type이 "namespace"일 때만 지정
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
    # Terraform 실행 주체(AWS SSO Role)에게 K8s ClusterAdmin 부여.
    # helm/kubernetes provider가 aws eks get-token --profile terraform으로 이 Role의 토큰을 발급받는다.
    # principal_arn은 data.aws_iam_session_context.current.issuer_arn으로 동적 참조 — SSO Role ARN 변경에 자동 대응.
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
