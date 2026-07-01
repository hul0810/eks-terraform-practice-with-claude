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

  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_endpoint  = data.terraform_remote_state.eks.outputs.cluster_endpoint
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  vpc_id            = data.aws_eks_cluster.this.vpc_config[0].vpc_id

  # eks/locals.tf의 kubernetes_version과 동기화
  cluster_version = "1.34"

  # monitoring: 단일 시스템 노드(비용 절감)로 모든 애드온 replica=1
  replica_counts = {
    lbc            = 1
    karpenter      = 1
    external_dns   = 1
    metrics_server = 1
    argo_rollouts  = 1
  }

  # *.pyhtest.com ACM 인증서 ARN — monitoring 계정, AWS CLI 외부 관리 리소스
  # 발급: aws acm request-certificate --domain-name "*.pyhtest.com" --validation-method DNS \
  #         --region ap-northeast-2 --profile terraform-monitoring
  # ARN 확인: aws acm list-certificates --region ap-northeast-2 --profile terraform-monitoring
  # 발급 후 아래 UUID를 실제 인증서 ID로 교체한다
  acm_certificate_arn = "arn:aws:acm:ap-northeast-2:${data.aws_caller_identity.current.account_id}:certificate/c23096ac-d684-4850-aea3-c0e5879622c1"

  # workload 계정 Route53 위임 Role ARN — ExternalDNS --aws-assume-role에 주입
  #
  # [최초 부트스트랩 순환 의존 해소]
  # monitoring/eks-addons와 route53-delegation이 서로의 output을 참조하는 양방향 의존이 발생한다.
  # try()로 소프트 참조를 만들어 route53-delegation state 미존재 시 "" 폴백 → 아래 순서로 적용한다:
  #   1단계: terraform apply                        (route53-delegation 참조 없이 ExternalDNS IRSA 생성)
  #   2단계: route53-delegation apply               (monitoring state에서 IRSA ARN 읽어 Trust Policy 설정)
  #   3단계: terraform apply                        (delegation role ARN 주입 → cross-account DNS 활성화)
  route53_delegation_role_arn = try(data.terraform_remote_state.route53_delegation.outputs.role_arn, "")

  eks_addons = {
    # 2026-06-09 기준 최신 stable 버전
    lbc_chart_version            = "3.4.0"
    external_dns_chart_version   = "1.14.5"
    metrics_server_chart_version = "3.12.2"
    karpenter_chart_version      = "1.12.1"

    enable_aws_load_balancer_controller = true
    enable_external_dns                 = true
    # pyhtest.com zone ARN — workload 계정 소유, Terraform 외부 관리 리소스 (하드코딩)
    # ExternalDNS IRSA가 route53_delegation_role_arn을 assume하여 이 zone에 접근한다
    external_dns_route53_zone_arns = ["arn:aws:route53:::hostedzone/Z0947901KS8HHREY0RFC"]
    enable_metrics_server          = true
    enable_karpenter               = true

    # monitoring 클러스터는 OTel의 Hub이므로 spoke collector를 설치하지 않는다.
    # OTel Operator와 Gateway는 observability/ root module에서 관리한다.
    enable_otel_spoke_collector = false

    enable_argocd        = true
    enable_argo_rollouts = false
    argocd_chart_version = "9.5.21"
    # monitoring: 단일 시스템 노드(비용 절감)라 HA 불필요
    argocd_ha_enabled = false

    # ArgoCD 외부 접근 설정 — argocd.pyhtest.com
    # ALB가 TLS를 종료하고 백엔드는 server.insecure=true로 평문 HTTP 서빙
    argocd_ingress_enabled  = true
    argocd_ingress_hostname = "argocd.pyhtest.com"
    # AWS ALB 이름 최대 32자 제한 — "eks-practice-argocd-mon-alb" = 28자
    argocd_ingress_alb_name = "${local.project}-argocd${local.name_suffix}-alb"
    # dex(SSO) 미활성 상태에서 admin 계정만으로 인증 → 운영자 IP로만 접근 허용
    argocd_ingress_allowed_cidrs = [data.aws_ssm_parameter.operator_ip_cidr.value]

    # ArgoCD admin 초기 패스워드 (bcrypt 해시)
    # 패스워드 변경 시: 새 해시와 argocd_admin_password_mtime을 함께 갱신해야 ArgoCD가 변경을 감지한다.
    # 해시 재생성: python3 -c "import bcrypt; print(bcrypt.hashpw(b'NEW_PASSWORD', bcrypt.gensalt()).decode())"
    # 주의: Terraform bcrypt() 함수를 직접 사용하지 말 것 — apply마다 ArgoCD pod 재시작 유발
    argocd_admin_password_bcrypt = data.aws_ssm_parameter.argocd_admin_password_bcrypt.value
    argocd_admin_password_mtime  = "2026-07-01T00:00:00Z"
  }

  karpenter_node_pools = {
    general = {
      capacity_types       = ["spot", "on-demand"]
      instance_families    = ["c", "m", "r"]
      architectures        = ["amd64"]
      instance_gen_min     = "2"
      weight               = 10
      taints               = []
      labels               = {}
      limits               = { cpu = "50", memory = "200Gi" }
      consolidation_policy = "WhenEmptyOrUnderutilized"
      consolidate_after    = "30s"
      disruption_budgets   = [{ nodes = "20%" }]
    }

    # Prometheus/Loki 등 EBS PVC를 사용하는 유상태 컴포넌트 전용 풀 (Phase 6 LGTM 배포 대비).
    # - capacity_types를 on-demand로 고정: spot 회수는 강제 종료라 karpenter.sh/do-not-disrupt
    #   annotation으로도 막을 수 없다. Phase 6 기준 Prometheus/Loki가 단일 replica라 회수 시
    #   수집 공백이 생긴다.
    # - taints로 무상태 워크로드를 밀어내고, labels로 유상태 파드가 nodeSelector로 이 풀이 만든
    #   노드만 명시적으로 선택하게 한다. taint는 "밀어내기"만 할 뿐 이 풀로 "끌어오지"는 못하므로
    #   (toleration만 있으면 general 풀의 무taint 노드에도 스케줄될 수 있음) labels가 필요하다.
    # - consolidationPolicy=WhenEmpty + consolidateAfter=10m: general의
    #   WhenEmptyOrUnderutilized+30s는 부하가 낮다는 이유만으로 30초 만에 노드를 교체 시도해
    #   PVC 재연결 지연·수집 공백을 유발할 수 있어 유상태 워크로드에는 과도하다.
    #
    # devops-manifest 저장소의 Helm values(Phase 6)에서 아래 값을 참조해 파드에 설정해야 한다:
    #   nodeSelector: { "eks-practice.io/workload-type" = "observability-stateful" }
    #   tolerations: [{ key = "observability-stateful", operator = "Equal", value = "true", effect = "NoSchedule" }]
    observability-stateful = {
      capacity_types    = ["on-demand"]
      instance_families = ["m", "r"]
      architectures     = ["amd64"]
      instance_gen_min  = "2"
      weight            = 10
      taints = [
        { key = "observability-stateful", value = "true", effect = "NoSchedule" }
      ]
      labels = {
        "eks-practice.io/workload-type" = "observability-stateful"
      }
      limits               = { cpu = "20", memory = "80Gi" }
      consolidation_policy = "WhenEmpty"
      consolidate_after    = "10m"
      # "20%"는 이 풀 규모(1~2노드)에서 내림 처리로 0이 되어 자발적 disruption 자체가
      # 영구 차단된다(WhenEmpty 정리도, AMI drift에 의한 노드 교체도 실행되지 않음).
      # 노드 수 기준 절대값으로 최소 1대는 항상 교체 가능하도록 보장한다.
      disruption_budgets = [{ nodes = "1" }]
    }
  }
}
