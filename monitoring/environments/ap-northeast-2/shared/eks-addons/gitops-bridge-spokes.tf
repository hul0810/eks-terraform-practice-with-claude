################################################################################
# GitOps Bridge Hub-Spoke — dev/prod cluster Secret을 monitoring의 argocd
# 네임스페이스에 생성해 Hub가 원격 클러스터를 관리 대상으로 인식하게 한다.
#
# [self-service 레지스트리로 전환 (gitops-bridge-registry.tf)]
# spoke 정보의 출처가 이 파일의 손으로 유지하던 map에서 SSM Parameter Store discovery로
# 바뀌었다 — local.gitops_bridge_spokes(locals.tf)가 discovery 결과를 "dev"/"prod" 별칭으로
# 재색인한 맵이다. spoke가 자신의 엔드포인트/CA/Role ARN/addon IAM 메타데이터를 이미 정확히
# 알고 있으므로, 이 root는 더 이상 크로스 계정 data source(aws_eks_cluster)로 조회하거나
# role_name 네이밍 패턴으로 IAM ARN을 추측 재조합하지 않는다.
#
# [monitoring-self와의 차이 — 왜 module.eks_addons(공유 모듈) 안이 아니라 root에 직접 두는가]
# 이 spoke Secret들은 dev/prod 자신의 addon IAM과는 무관하다 — 별도 계정·별도 root라 공유
# 모듈을 거칠 이유가 없어 벤더 모듈(gitops-bridge-dev/gitops-bridge/helm)을 이 root에서
# 바로 호출한다.
#
# [install=false인 이유]
# ArgoCD 자신은 이미 module.eks_addons(gitops_bridge_bootstrap)가 설치했다. 이 모듈을
# 또 호출하면서 install=true를 주면 같은 네임스페이스에 두 번째 ArgoCD Helm release를
# 만들려 시도해 충돌한다 — create=true(Secret은 만듦)/install=false(Helm은 재설치 안 함)
# 조합이 정확히 이 상황을 위해 벤더가 분리해둔 두 스위치다.
#
# [roleARN — cross-account 인증 경로]
# 이 Secret의 config.awsAuthConfig.roleARN은 project/environments/{develop,production}/
# .../eks-addons/gitops-bridge-spoke-irsa.tf가 만든 spoke Role을 가리킨다(레지스트리
# payload의 spoke_role_arn — spoke가 자기 자신의 Role ARN을 정확히 알려주므로 Hub가
# 이름 패턴으로 재구성하지 않는다). Hub의 argocd_application_controller Role이 이 spoke
# Role을 sts:AssumeRole로 넘겨받아 그 계정의 EKS API에 접근한다(gitops-bridge-irsa.tf의
# 크로스 계정 assume 권한과 대칭).
#
# [cluster_name — 실제 EKS 이름과 라우팅 별칭을 분리해서 쓴다]
# each.key("dev"/"prod")는 devops-manifest ApplicationSet이 매칭하는 라우팅 별칭이고,
# each.value.cluster_name(레지스트리 payload)은 실제 EKS 클러스터 이름이다. 이 둘을
# 섞으면 안 된다 — config.awsAuthConfig.clusterName처럼 AWS IAM Authenticator가 실제로
# 인증에 쓰는 값은 반드시 실제 클러스터 이름이어야 하고, cluster.cluster_name처럼
# ApplicationSet이 `{{name}}`으로 셀렉터·destination에 쓰는 값은 반드시 별칭이어야 한다
# (locals.tf의 environment_spoke_alias 주석 참조 — 이미 devops-manifest의 workload
# ApplicationSet들이 이 별칭으로 라우팅되고 있어 바꾸면 실제 배포가 깨진다).
################################################################################

module "gitops_bridge_spoke" {
  for_each = local.gitops_bridge_spokes
  source   = "gitops-bridge-dev/gitops-bridge/helm"
  version  = "~> 0.1.0"

  create  = true
  install = false

  cluster = {
    cluster_name = each.key # "dev"/"prod" — ApplicationSet의 {{name}}으로 노출되는 라우팅 별칭
    environment  = each.value.environment
    # [WHY] devops-manifest의 addon selector가 이 라벨이 있는 spoke만 addon 배포 대상으로
    # 포함한다.
    addons = merge(
      { "eks-practice.io/gitops-bridge-role" = "spoke" },
      each.value.addon_managed ? { "eks-practice.io/addon-managed" = "true" } : {}
    )
    server = each.value.cluster_endpoint
    config = jsonencode({
      awsAuthConfig = {
        clusterName = each.value.cluster_name
        roleARN     = each.value.spoke_role_arn
      }
      tlsClientConfig = {
        caData = each.value.cluster_ca_data
      }
    })
    # [WHY] devops-manifest의 LBC/Karpenter/ExternalDNS/ExternalSecrets ApplicationSet은
    # `{{metadata.annotations.<key>}}`로 이 addon들의 IAM Role ARN을 Helm values에 주입한다.
    # gitops_metadata는 spoke가 자기 module.eks_addons의 공식 output(gitops_bridge_addon_metadata,
    # aws-ia/eks-blueprints-addons 벤더 output을 그대로 통과)을 레지스트리에 실어 보낸 값이다
    # — 계정 ID·네이밍 패턴을 몰라도 항상 정확하다.
    metadata = merge(
      {
        aws_cluster_name = each.value.cluster_name
        aws_region       = each.value.aws_region
        aws_account_id   = each.value.aws_account_id
        vpc_id           = each.value.vpc_id
      },
      each.value.addon_managed ? merge(
        try(each.value.gitops_metadata, {}),
        # [벤더 output에 없는 project 고유 필드]
        # karpenter_discovery_tag/consolidate_after/nodepool_*_enabled는 aws-ia/eks-blueprints-addons의
        # gitops_metadata에 없다 — 이 프로젝트가 독자로 도입한 필드라 vendor가 알 수 없다.
        # devops-manifest의 karpenter-resources-spoke가 이 값들을 required로 요구하므로
        # (charts/eks-addons/karpenter-resources/templates/ec2nodeclass.yaml) 빠지면 dev의
        # NodePool 배포 자체가 깨진다 — spoke가 이미 알고 있는 값이라 레지스트리에 함께 싣는다.
        try(each.value.karpenter_nodepool_metadata, {})
      ) : {}
    )
  }

  apps = {}
}
