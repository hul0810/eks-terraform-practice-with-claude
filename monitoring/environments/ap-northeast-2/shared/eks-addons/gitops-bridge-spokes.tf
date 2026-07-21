################################################################################
# GitOps Bridge Hub-Spoke — dev/prod cluster Secret을 monitoring의 argocd
# 네임스페이스에 생성해 Hub가 원격 클러스터를 관리 대상으로 인식하게 한다.
#
# [monitoring-self와의 차이 — 왜 module.eks_addons(공유 모듈) 안이 아니라 root에 직접 두는가]
# 이 spoke Secret들은 dev/prod 자신의 addon IAM과는 무관하다 — 별도 계정·별도 root라 그
# addon IAM ARN(module.eks_addons의 gitops_metadata output)을 읽으려면 cross-account
# remote_state가 필요한데, 대신 role_name 네이밍 패턴을 문자열로 직접 조합한다(아래
# addon_iam_metadata 참고). 공유 모듈을 거칠 이유가 없어 벤더 모듈
# (gitops-bridge-dev/gitops-bridge/helm)을 이 root에서 바로 호출한다.
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
# 계정의 EKS API에 접근한다(gitops-bridge-irsa.tf의 크로스 계정 assume 권한과 대칭).
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
      # devops-manifest의 addon selector가 이 라벨이 있는 spoke만 addon 배포 대상으로
      # 포함한다.
      addon_managed = true
      # dev/eks-addons/karpenter.tf의 disruption.consolidateAfter(arm64/gpu/spot NodePool)와
      # 동일 값 — karpenter-resources 차트가 이 값을 그대로 템플릿에 주입한다.
      karpenter_consolidate_after = "30s"
      # 워크로드(dev/prod)는 general/arm64/gpu/spot 4종 NodePool을 전부 쓰고, monitoring은
      # GPU가 필요 없어 값을 아예 안 받고 devops-manifest values-override.yaml에서 false로
      # 고정한다(그래서 monitoring-self의 metadata에는 이 3개 키가 없다 — 아래 module
      # "gitops_bridge_spoke"의 metadata는 이 root가 spoke에만 넘긴다).
      karpenter_nodepool_arm64_enabled = "true"
      karpenter_nodepool_gpu_enabled   = "true"
      karpenter_nodepool_spot_enabled  = "true"
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
      # dev와 동일하게 미리 채워뒀다 — addon_managed=false인 동안은 addon_iam_metadata의
      # 삼항식이 {}를 반환해 spoke Secret에 실제로는 반영되지 않는 죽은 값이다. prod의
      # addon_managed를 true로 바꾸는 시점에 이 값 그대로 둘지(워크로드 전체 NodePool
      # 사용) 재검토할 것.
      karpenter_nodepool_arm64_enabled = "true"
      karpenter_nodepool_gpu_enabled   = "true"
      karpenter_nodepool_spot_enabled  = "true"
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
  # modules/eks-addons/2.0.0/main.tf가 고정한 role_name 패턴(${cluster_name}-lbc-irsa 등,
  # role_name_use_prefix=false)을 문자열로 그대로 조합한다 — 이 파일의 roleARN(위
  # config.awsAuthConfig)과 동일한 방식이라 계정 ID·네이밍이 바뀌지 않는 한 안전하다.
  # cross-account remote_state로 dev 자신의 gitops_metadata output을 직접 읽는 방식으로
  # 바꾸면 이 local 자체가 필요 없어지지만, 지금은 그 정도 리팩토링 없이도 정확히 동작한다.
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
        # karpenter-resources 차트가 이 값으로 arm64/gpu/spot NodePool 생성 여부를 결정한다.
        # karpenter-resources 자체가 addon_managed spoke만 대상이라 이 3개도 같은 조건
        # (addon_managed) 안에 둔다.
        karpenter_nodepool_arm64_enabled = spoke.karpenter_nodepool_arm64_enabled
        karpenter_nodepool_gpu_enabled   = spoke.karpenter_nodepool_gpu_enabled
        karpenter_nodepool_spot_enabled  = spoke.karpenter_nodepool_spot_enabled
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
    # [WHY] devops-manifest의 addon ApplicationSet은 이 Secret의 `eks-practice.io/
    # addon-managed` 라벨이 있는 spoke만 포함 목록에 넣는다 — dev가 addon 이관 준비가
    # 됐을 때만 이 라벨을 붙인다(prod는 아직 안 붙임). `eks-practice.io/gitops-bridge-role:
    # spoke` 라벨은 workload(catalog/gateway/order) ApplicationSet 6개가 이 Secret의
    # cluster_name으로 매칭해 destination.name을 '{{.name}}'으로 템플릿화하는 데 쓰인다 —
    # 즉 워크로드가 monitoring이 아니라 실제 dev/prod로 배포된다.
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
