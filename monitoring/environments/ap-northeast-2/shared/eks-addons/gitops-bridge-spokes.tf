################################################################################
# GitOps Bridge Hub-Spoke(Phase 6-5) — dev/prod cluster Secret을 monitoring의 argocd
# 네임스페이스에 생성해 Hub가 원격 클러스터를 관리 대상으로 인식하게 한다.
#
# [monitoring-self와의 차이 — 왜 module.eks_addons(공유 모듈) 안이 아니라 root에 직접 두는가]
# monitoring-self는 module.eks_addons에 gitops_bridge_hub 변수로 넘겨서, 공유 모듈 내부에서
# 자기 자신의 addon IAM ARN(module.eks_blueprints_addons_gitops.gitops_metadata)과 합쳐야
# 했다(순환 참조 회피 목적). 이 spoke Secret들은 dev/prod 자신의 addon IAM과는 무관하다 —
# dev는 2026-07-21 `2.0.0`으로 전환 완료했지만(prod는 코드만), 이 local의
# addon_iam_metadata는 아직 dev 자신의 `module.eks_addons`가 노출하는 gitops_metadata
# output을 직접 참조하도록 배선하지 않은 상태다(같은 계정도 아니고 별도 root라 그 output을
# 읽으려면 cross-account remote_state가 필요 — 아래 addon_iam_metadata WHY 참고). 그래서
# 공유 모듈을 거칠 이유가 없어 벤더 모듈(gitops-bridge-dev/gitops-bridge/helm)을 이 root에서
# 바로 호출한다.
#
# [install=false인 이유]
# ArgoCD 자신은 이미 module.eks_addons(gitops_bridge_bootstrap)가 설치했다. 이 모듈을
# 또 호출하면서 install=true를 주면 같은 네임스페이스에 두 번째 ArgoCD Helm release를
# 만들려 시도해 충돌한다 — create=true(Secret은 만듦)/install=false(Helm은 재설치 안 함)
# 조합이 정확히 이 상황을 위해 벤더가 분리해둔 두 스위치다.
#
# [크로스 계정 조회 — provider "aws.workload"]
# dev/prod EKS 클러스터는 workload 계정(657231015203)에 있어 monitoring의 기본 AWS
# provider로는 조회가 안 된다. providers.tf에 추가한 aws.workload provider alias로
# 클러스터 endpoint/CA를 직접 조회한다(cross-account remote_state 대신 로컬에 이미
# 구성된 terraform-workload 프로필을 재사용 — 버킷 정책 변경 불필요).
#
# [roleARN — cross-account 인증 경로]
# 이 Secret의 config.awsAuthConfig.roleARN은 project/environments/{develop,production}/
# .../eks-addons/gitops-bridge-spoke-irsa.tf가 만든 spoke Role을 가리킨다. Hub의
# argocd_application_controller Role이 이 spoke Role을 sts:AssumeRole로 넘겨받아 그
# 계정의 EKS API에 접근한다(gitops-bridge-irsa.tf 3단 체인과 대칭되는 크로스 계정 버전).
#
# [지금은 dev만 활성화]
# prod EKS 클러스터는 현재 꺼져있다(비용 절감, teardown 상태) — enabled_gitops_bridge_spokes가
# prod를 걸러내므로 data "aws_eks_cluster"가 prod를 조회하지 않는다(조회 시도하면 클러스터가
# 없어 에러남). dev 검증이 끝나면 아래 gitops_bridge_spokes 맵에서 prod.enabled를 true로
# 바꾸고 prod를 프로비저닝한 뒤 적용한다.
################################################################################

locals {
  gitops_bridge_spokes = {
    dev = {
      enabled          = true
      aws_cluster_name = "eks-practice-dev"
      environment      = "develop"
      # 6-5 이후: dev의 addon(LBC/Karpenter/ExternalDNS/ExternalSecrets/metrics-server/
      # argo-rollouts)을 Terraform-Helm에서 Argo 배포로 이관 중 — devops-manifest의 addon
      # selector가 이 라벨이 있는 spoke만 포함하도록 전환됨(2026-07-21).
      addon_managed = true
      # dev/eks-addons/karpenter.tf의 disruption.consolidateAfter(arm64/gpu/spot NodePool)와
      # 동일 값 — karpenter-resources 차트가 이 값을 그대로 템플릿에 주입한다(2026-07-21).
      karpenter_consolidate_after = "30s"
    }
    prod = {
      enabled          = false
      aws_cluster_name = "eks-practice"
      environment      = "production"
      # prod는 dev 이관 검증 전까지 addon 배포 대상에서 제외(라벨 없음).
      addon_managed = false
      # production/eks-addons/karpenter.tf와 동일 값(dev보다 긴 300s — 스파이크 직후 과도한
      # 노드 회수 방지).
      karpenter_consolidate_after = "300s"
    }
  }

  enabled_gitops_bridge_spokes = {
    for name, spoke in local.gitops_bridge_spokes : name => spoke if spoke.enabled
  }

  # [WHY] devops-manifest의 LBC/Karpenter/ExternalDNS/ExternalSecrets ApplicationSet은
  # `{{metadata.annotations.<key>}}`로 이 addon들의 IAM Role ARN을 Helm values에 주입한다
  # (예: serviceAccount.annotations.eks.amazonaws.com/role-arn). spoke(dev/prod)는 monitoring
  # 자신처럼 형제 module의 gitops_metadata output을 참조할 수 없다 — 별도 root(다른 AWS
  # 계정)라 그 output을 읽으려면 cross-account remote_state가 필요하기 때문이다. 대신
  # modules/eks-addons/2.0.0/main.tf(dev가 2026-07-21부터 실제 참조 중)가 고정한 role_name
  # 패턴(${cluster_name}-lbc-irsa 등, role_name_use_prefix=false)을 그대로 조합한다 — 1.0.0도
  # 동일한 네이밍 규칙을 썼으므로 이 문자열 조합은 dev의 1.0.0→2.0.0 전환 전후로 값이
  # 바뀌지 않는다. 이 파일의 roleARN(위 config.awsAuthConfig)과 동일한 방식(데이터소스 대신
  # 문자열 조합)이라 계정 ID·네이밍이 바뀌지 않는 한 안전하다. cross-account remote_state로
  # dev 자신의 gitops_metadata output을 직접 읽는 방식으로 바꾸면 이 local 자체가 필요
  # 없어지지만, 지금은 그 정도 리팩토링 없이도 정확히 동작한다.
  addon_iam_metadata = {
    for name, spoke in local.gitops_bridge_spokes : name => (
      spoke.addon_managed ? {
        aws_load_balancer_controller_iam_role_arn = "arn:aws:iam::${local.workload_account_id}:role/${spoke.aws_cluster_name}-lbc-irsa"
        karpenter_iam_role_arn                    = "arn:aws:iam::${local.workload_account_id}:role/${spoke.aws_cluster_name}-karpenter-controller-irsa"
        karpenter_node_iam_role_name              = "${spoke.aws_cluster_name}-karpenter-node"
        # dev/eks/locals.tf의 node_security_group_tags["karpenter.sh/discovery"] 값과 동일 —
        # 그 local도 "${project}${name_suffix}"로 aws_cluster_name과 같은 값을 만든다.
        karpenter_discovery_tag = spoke.aws_cluster_name
        # modules/eks-addons/1.0.0/main.tf의 karpenter_sqs.queue_name = "${cluster_name}-karpenter" 패턴
        karpenter_sqs_queue_name      = "${spoke.aws_cluster_name}-karpenter"
        karpenter_consolidate_after   = spoke.karpenter_consolidate_after
        external_dns_iam_role_arn     = "arn:aws:iam::${local.workload_account_id}:role/${spoke.aws_cluster_name}-external-dns-irsa"
        external_secrets_iam_role_arn = "arn:aws:iam::${local.workload_account_id}:role/${spoke.aws_cluster_name}-external-secrets-irsa"
      } : {}
    )
  }
}

data "aws_eks_cluster" "spoke" {
  for_each = local.enabled_gitops_bridge_spokes
  provider = aws.workload
  name     = each.value.aws_cluster_name
}

module "gitops_bridge_spoke" {
  for_each = local.enabled_gitops_bridge_spokes
  source   = "gitops-bridge-dev/gitops-bridge/helm"
  version  = "~> 0.1.0"

  create  = true
  install = false

  cluster = {
    cluster_name = each.key # "dev"/"prod" — ApplicationSet의 {{name}}으로 노출되는 값
    environment  = each.value.environment
    # [WHY] addon 10개 ApplicationSet의 clusters generator selector가 원래
    # `argocd.argoproj.io/secret-type: cluster` 하나만 보고 있어서, 이 Secret이 생기자마자
    # monitoring 전용이어야 할 addon 10개가 "-dev" Application으로 잘못 자동 생성되고
    # destination이 in-cluster로 고정돼 있어 monitoring 자신의 기존 리소스와
    # SharedResourceWarning(소유권 충돌)까지 발생했다(2026-07-21 실제 발생).
    # devops-manifest 쪽에서 addon selector에 이 라벨 NotIn 조건을 추가해 spoke Secret을
    # 제외하도록 수정 완료(2026-07-21, push+라이브 반영 확인) — 지금은 정상적으로 걸러진다.
    # workload(catalog/gateway/order) ApplicationSet 6개도 이 라벨(정확히는 spoke의
    # cluster_name)로 매칭해 destination.name을 '{{.name}}'으로 템플릿화하도록 함께 전환됨 —
    # 실제 workload가 monitoring이 아니라 진짜 dev/prod로 배포되기 시작했다.
    #
    # [addon-managed — 6-5 이후] addon selector가 "제외 목록"(spoke면 무조건 뺌)에서
    # "포함 목록"(이 라벨이 있는 spoke만 포함) 방식으로 바뀌었다(devops-manifest 요청·반영,
    # 2026-07-21). dev가 addon 이관 준비가 됐을 때만 이 라벨을 붙인다 — prod는 아직 안 붙임.
    addons = merge(
      { "eks-practice.io/gitops-bridge-role" = "spoke" },
      each.value.addon_managed ? { "eks-practice.io/addon-managed" = "true" } : {}
    )
    server = data.aws_eks_cluster.spoke[each.key].endpoint
    config = jsonencode({
      awsAuthConfig = {
        clusterName = each.value.aws_cluster_name
        roleARN     = "arn:aws:iam::${local.workload_account_id}:role/${each.value.aws_cluster_name}-argocd-spoke-irsa"
      }
      tlsClientConfig = {
        caData = data.aws_eks_cluster.spoke[each.key].certificate_authority[0].data
      }
    })
    metadata = merge(
      {
        aws_cluster_name = each.value.aws_cluster_name
        aws_region       = "ap-northeast-2"
        aws_account_id   = local.workload_account_id
        vpc_id           = data.aws_eks_cluster.spoke[each.key].vpc_config[0].vpc_id
      },
      local.addon_iam_metadata[each.key]
    )
  }

  apps = {}
}
