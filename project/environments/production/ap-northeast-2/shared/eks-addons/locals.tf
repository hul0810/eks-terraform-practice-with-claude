locals {
  environment = "production"
  project     = "eks-practice"

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  # pyhtest.com ACM 인증서 — workload 계정, Terraform 외부 관리 리소스 (account_id는 런타임 조회)
  acm_certificate_arn = "arn:aws:acm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:certificate/25f64604-759b-42b2-8734-69b3d0d9cfb7"

  # eks/ state에서 참조하는 클러스터 정보
  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.eks.outputs.cluster_endpoint
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  # aws_eks_cluster data source로 VPC ID 조회 — remote_state에 vpc_id output이 없어 data source 활용
  vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # eks/locals.tf의 kubernetes_version과 동기화 — EKS 버전 업그레이드 시 함께 변경한다
  cluster_version = "1.34"

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전 (external_secrets_chart_version은 2026-07-02 기준)
    # 버전 업그레이드: helm repo update && helm search repo <chart> --versions
    # metrics-server/argo-rollouts는 여기 없다 — IAM이 필요 없는 addon이라 Terraform이
    # 완전히 손을 떼고, Helm 관리·버전은 devops-manifest ArgoCD Application이 전담한다
    # (dev와 동일 패턴, modules/eks-addons/2.0.0/CLAUDE.md 참조).
    lbc_chart_version              = "3.4.0"
    external_dns_chart_version     = "1.14.5"
    karpenter_chart_version        = "1.12.1"
    argocd_chart_version           = "9.5.21"
    external_secrets_chart_version = "2.7.0"

    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    # pyhtest.com zone ARN — workload 계정 hosted zone, Terraform 외부 관리 리소스 (하드코딩)
    external_dns_route53_zone_arns = ["arn:aws:route53:::hostedzone/Z0947901KS8HHREY0RFC"]
    enable_karpenter               = true
    # production은 monitoring ArgoCD Hub의 spoke로 등록되어 개별 ArgoCD 설치를 쓰지 않는다
    # (gitops-bridge-spoke-irsa.tf가 그 spoke 등록을 담당). 코드만 반영되어 있고 production
    # apply는 사용자가 직접 실행한다(CLAUDE.md "Production 배포 정책", 훅이 어차피 차단).
    # 아래 argocd_* 값들은 enable_argocd=false인 동안 전부 미사용이지만, 일부는 모듈 쪽
    # 필수 인자라 값은 남겨둔다.
    enable_argocd = false
    # SecretStore/ClusterSecretStore·ExternalSecret CR 구성은 다음 단계 — 이번 단계는 애드온 설치까지.
    # IAM 스코프는 blueprints 기본 와일드카드(계정 전체 SSM/KMS) 대신 이 환경의 SSM 경로(/eks-practice/production/*)로
    # 미리 좁혀둔다 — 아직 이 경로에 파라미터가 없어도, 향후 SecretStore 구성 시 별도 IAM 변경 없이 바로 쓸 수 있다.
    enable_external_secrets = true
    external_secrets_ssm_parameter_arns = [
      "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/production/*"
    ]
    external_secrets_kms_key_arns = [data.aws_kms_alias.ssm_default.target_key_arn]
    # 시스템 노드 min/desired=1(비용 예외, eks/locals.tf 참조)인 상태에서 HA를 켜면
    # redis-ha quorum이 spot 노드에 분산되어 단일 노드 장애 시 ArgoCD 전체가 다운될 수 있다.
    # 시스템 노드 HA 복원(min/desired=2) 시 true로 함께 전환할 것 (redis-ha + replica=2).
    argocd_ha_enabled      = false
    argocd_ingress_enabled = true
    # monitoring 클러스터가 "argocd.pyhtest.com" Hub를 운영하므로 production은 별도 subdomain 사용
    argocd_ingress_hostname = "argocd-production.pyhtest.com"
    argocd_ingress_alb_name = "eks-practice-argocd-prd-alb"
    # dex 비활성화 상태(기본 admin 계정만 인증)이므로 ALB SG inbound를 작업자 IP로 제한
    argocd_ingress_allowed_cidrs = [data.aws_ssm_parameter.operator_ip_cidr.value]

    # ArgoCD admin 초기 패스워드 (bcrypt 해시). 해시 생성일: 2026-06-16
    # dev 환경과 동일 패스워드 사용 (실습 환경 — 운영 환경에서는 별도 패스워드 설정 권장)
    # 패스워드 변경 시: 새 해시와 argocd_admin_password_mtime을 함께 갱신해야 ArgoCD가 변경을 감지한다.
    # 해시 재생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt()).decode())"
    # 주의: Terraform bcrypt() 함수를 직접 사용하지 말 것 — apply마다 ArgoCD pod 재시작 유발
    argocd_admin_password_bcrypt = data.aws_ssm_parameter.argocd_admin_password_bcrypt.value
    argocd_admin_password_mtime  = "2026-06-16T00:00:00Z"

    # OTel Spoke Collector (GitOps로 OTel Gateway 배포 완료 후 활성화)
    # 활성화 순서:
    #   1. monitoring vpc apply → prd vpc peering_routes 주석 해제 + pcx ID 입력 → apply
    #   2. Phase 6 ArgoCD Hub-Spoke 구성 후 devops-manifest 저장소에서 OTel Gateway 배포
    #   3. OTel Gateway Internal NLB DNS 확인 후 아래 값 설정 → apply
    enable_otel_spoke_collector       = false
    otel_gateway_endpoint             = "" # "<NLB DNS>:4317" — ArgoCD 배포 후 Internal NLB DNS 확인
    otel_spoke_operator_chart_version = "0.76.1"
  }

  # Karpenter NodePool 정의는 여기 없다 — 4종(general/arm64/gpu/spot) 전부
  # devops-manifest의 karpenter-resources Application이 EC2NodeClass "default"와
  # 함께 관리한다(karpenter.tf 상단 WHY 참조).
}

################################################################################
# GitOps Bridge Registry — self-service 등록 payload (gitops-bridge-registry.tf 참조)
#
# project/environments/develop/.../eks-addons/locals.tf의 동일 블록을 그대로 본떴다 —
# 구조·필드는 전부 동일하고 값만 production 자신의 것으로 채운다.
################################################################################
locals {
  # monitoring(Hub) 계정 ID 및 레지스트리 writer Role ARN — 크로스 계정 하드코딩 리소스.
  # acm_certificate_arn 등 이 파일의 다른 하드코딩과 동일한 이유: 2계정 토폴로지 자체가
  # 프로젝트 구조 상수라 remote_state로 조회할 이유가 없다(providers.tf가 이 값으로
  # aws.gitops_bridge_registry provider의 assume_role.role_arn을 구성한다).
  monitoring_account_id = "157325288431"
  # 계정마다 별도 Role(monitoring/.../eks-addons/gitops-bridge-registry.tf 참조 — 이 계정
  # 전용으로 Resource가 하드코딩된 정책만 가진 Role). 이름 접미사가 이 계정 ID와 일치해야 한다.
  #
  # [주의 — "eks-practice-mon" 리터럴은 Hub의 cluster_name 네이밍 규칙을 여기서 다시
  # 하드코딩한 것] Hub monitoring의 environment_short("mon")가 바뀌면 이 문자열도 함께
  # 갱신해야 하는데, 안 맞아도 컴파일 에러 없이 AccessDenied로 조용히 깨진다(develop의
  # 동일 local과 같은 주의사항).
  gitops_bridge_registry_writer_role_arn = "arn:aws:iam::${local.monitoring_account_id}:role/eks-practice-mon-gitops-bridge-registry-writer-${data.aws_caller_identity.current.account_id}"

  # [스키마 계약]
  # Hub(monitoring/environments/.../eks-addons/gitops-bridge-spokes.tf)가 이 구조를 그대로
  # discovery해서 소비한다 — 필드를 추가/제거하면 Hub 쪽도 함께 맞춰야 한다.
  # cluster_name은 "prod" 같은 논리적 별칭이 아니라 실제 EKS 클러스터 이름 그대로 담는다
  # (대상 식별 가능해야 한다는 원칙, docs/terraform-principles.md 참조) — ArgoCD
  # ApplicationSet 라우팅에 쓰는 "dev"/"prod" 별칭은 Hub가 environment 필드로부터 별도로
  # 유도한다(monitoring locals.tf의 environment_spoke_alias).
  gitops_bridge_registry_payload = {
    schema_version   = 1
    cluster_name     = local.cluster_name
    environment      = local.environment
    aws_account_id   = data.aws_caller_identity.current.account_id
    aws_region       = "ap-northeast-2"
    vpc_id           = local.vpc_id
    cluster_endpoint = data.aws_eks_cluster.this.endpoint
    cluster_ca_data  = data.aws_eks_cluster.this.certificate_authority[0].data
    spoke_role_arn   = aws_iam_role.gitops_bridge_spoke.arn
    addon_managed    = true
    # aws-ia/eks-blueprints-addons 벤더 output을 그대로 통과시킨 값(modules/eks-addons/2.0.0/
    # outputs.tf) — LBC/ExternalDNS/ExternalSecrets/Karpenter IAM Role ARN 등을 Hub가 이름
    # 패턴으로 추측하지 않고 그대로 전달한다.
    gitops_metadata = module.eks_addons.gitops_bridge_addon_metadata

    # [벤더 output에 없는 project 고유 필드]
    # karpenter_discovery_tag/consolidate_after/nodepool_*_enabled는 gitops_metadata(vendor
    # pass-through)에 없는, 이 프로젝트가 독자로 도입한 필드다. devops-manifest의
    # karpenter-resources-spoke ApplicationSet(charts/eks-addons/karpenter-resources)이
    # nodeRole 외에 discoveryTag/consolidateAfter를 required 값으로 요구하고, arm64/gpu/spot
    # NodePool on/off도 이 값들로 결정한다 — 빠지면 production의 NodePool 배포 자체가 깨진다.
    karpenter_nodepool_metadata = {
      # eks/locals.tf의 node_security_group_tags["karpenter.sh/discovery"]와 동일한 값 —
      # 그 local도 "${project}${name_suffix}"로 local.cluster_name과 같은 값을 만든다.
      karpenter_discovery_tag = local.cluster_name
      # dev(30s)보다 긴 값 — 스파이크 직후 과도한 노드 회수를 방지한다(karpenter.tf 상단
      # 주석 및 과거 monitoring gitops-bridge-spokes.tf의 prod 항목과 동일 값 유지).
      karpenter_consolidate_after      = "300s"
      karpenter_nodepool_arm64_enabled = "true"
      karpenter_nodepool_gpu_enabled   = "true"
      karpenter_nodepool_spot_enabled  = "true"
    }
  }
}
