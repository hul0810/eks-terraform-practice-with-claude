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
    # metrics-server/argo-rollouts는 여기 없다 — IAM이 필요 없는 addon이라 6-5 이후
    # Terraform이 완전히 손을 뗐고(2026-07-21), Helm 관리·버전은 devops-manifest
    # ArgoCD Application이 전담한다(modules/eks-addons/2.0.0/CLAUDE.md 참조).
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
    # Phase 6-5: dev를 monitoring ArgoCD Hub의 spoke로 등록하며 개별 설치를 롤백한다
    # (gitops-bridge-spoke-irsa.tf가 그 spoke 등록을 대신 담당). 아래 argocd_* 값들은
    # enable_argocd=false인 동안 전부 미사용이지만, argocd_chart_version 등 일부는 모듈
    # 쪽에 기본값이 없는 필수 인자라 값 자체는 남겨둔다 — 다시 켤 일이 생기면 그대로 재사용.
    enable_argocd = false
    # SecretStore/ClusterSecretStore·ExternalSecret CR 구성은 다음 단계 — 이번 단계는 애드온 설치까지.
    # IAM 스코프는 blueprints 기본 와일드카드(계정 전체 SSM/KMS) 대신 이 환경의 SSM 경로(/eks-practice/develop/*)로
    # 미리 좁혀둔다 — 아직 이 경로에 파라미터가 없어도, 향후 SecretStore 구성 시 별도 IAM 변경 없이 바로 쓸 수 있다.
    enable_external_secrets = true
    external_secrets_ssm_parameter_arns = [
      "arn:aws:ssm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:parameter/eks-practice/develop/*"
    ]
    external_secrets_kms_key_arns = [data.aws_kms_alias.ssm_default.target_key_arn]
    argocd_ha_enabled             = false # dev: 단일 시스템 노드, 비용 절감 (redis-ha 등 추가 pod 회피)
    argocd_ingress_enabled        = true
    argocd_ingress_hostname       = "argocd-develop.pyhtest.com"
    argocd_ingress_alb_name       = "${local.project}-argocd${local.name_suffix}-alb"
    # dex 비활성화 상태(기본 admin 계정만 인증)이므로 ALB SG inbound를 내 IP로 제한
    argocd_ingress_allowed_cidrs = [data.aws_ssm_parameter.operator_ip_cidr.value]

    # ArgoCD admin 초기 패스워드 (bcrypt 해시). 해시 생성일: 2026-06-16
    # 패스워드 변경 시: 새 해시와 argocd_admin_password_mtime을 함께 갱신해야 ArgoCD가 변경을 감지한다.
    # 해시 재생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt()).decode())"
    # 주의: Terraform bcrypt() 함수를 직접 사용하지 말 것 — apply마다 ArgoCD pod 재시작 유발
    argocd_admin_password_bcrypt = data.aws_ssm_parameter.argocd_admin_password_bcrypt.value
    argocd_admin_password_mtime  = "2026-06-16T00:00:00Z"

    # OTel Spoke Collector (GitOps로 OTel Gateway 배포 완료 후 활성화)
    # 활성화 순서:
    #   1. monitoring vpc apply → dev vpc peering_routes 주석 해제 + pcx ID 입력 → apply
    #   2. Phase 6 ArgoCD Hub-Spoke 구성 후 devops-manifest 저장소에서 OTel Gateway 배포
    #   3. OTel Gateway Internal NLB DNS 확인 후 아래 값 설정 → apply
    enable_otel_spoke_collector       = false
    otel_gateway_endpoint             = "" # "<NLB DNS>:4317" — ArgoCD 배포 후 Internal NLB DNS 확인
    otel_spoke_operator_chart_version = "0.76.1"
  }

  # Karpenter NodePool 정의는 여기 없다 — 4종(general/arm64/gpu/spot) 전부
  # devops-manifest의 karpenter-resources-dev Application이 EC2NodeClass "default"와
  # 함께 관리한다(karpenter.tf 상단 WHY 참조, 2026-07-21).
}
