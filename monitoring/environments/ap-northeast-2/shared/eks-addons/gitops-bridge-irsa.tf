################################################################################
# GitOps Bridge Hub — argocd-application-controller IRSA
#
# 이 Role은 monitoring 자기 자신을 위한 것이 아니라, Hub가 dev/prd(workload 계정)
# spoke 클러스터를 원격 관리하기 위한 크로스 계정 identity다 — argocd-application-controller
# 파드가 이 Role을 IRSA로 assume한 뒤, 그 신원으로 dev/prd 각각의 spoke Role
# (gitops-bridge-spoke-irsa.tf)을 추가로 sts:AssumeRole한다(아래
# aws_iam_role_policy.argocd_hub_assume_spokes). monitoring 자신에 대한 K8s 인가(RBAC)는
# 이 파일의 책임이 아니다 — ArgoCD 자신을 대상으로 하는 모든 ApplicationSet이
# `destination: name: in-cluster`(ArgoCD 내장 ServiceAccount 권한)를 쓰므로, monitoring
# 자신을 향한 별도 Access Entry+RBAC 체인은 필요 없다. vendor 모듈
# (gitops-bridge-dev/gitops-bridge/helm)도 cluster.server/cluster.config를 안 넘기면
# `server = https://kubernetes.default.svc`, `config = {tlsClientConfig: {insecure:
# false}}`(awsAuthConfig 없음)로 자동 대체한다(아래 local.gitops_bridge_hub_cluster 참고).
################################################################################

# STS AssumeRoleWithWebIdentity(OIDC federation) 자체는 별도 IAM 권한(inline policy)이
# 필요 없다 — 이 Role은 "누가 이 신원인지"만 증명하는 용도이고, 실제로 쓰는 권한은 아래
# aws_iam_role_policy.argocd_hub_assume_spokes(dev/prd spoke Role을 assume하는 권한)뿐이다.
# dev/prd 같은 크로스 계정 spoke를 awsAuthConfig.roleARN으로 등록하려면 이 Role이 그
# 계정의 spoke Role을 sts:AssumeRole로 불러올 권한이 별도로 필요하다 — 신뢰 정책(대상
# Role 쪽에서 "누가 나를 assume할 수 있는가")과 권한 정책(이 Role 쪽에서 "내가 무엇을
# assume할 수 있는가")은 양방향으로 각각 허용돼야 하는 별개의 정책이다.
resource "aws_iam_role" "argocd_application_controller" {
  name = "${local.cluster_name}-argocd-hub-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ArgocdApplicationControllerIrsa"
        Effect    = "Allow"
        Principal = { Federated = local.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:argocd:argocd-application-controller"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# gitops-bridge-spokes.tf가 만드는 spoke Role(project/environments/{develop,production}/
# .../eks-addons/gitops-bridge-spoke-irsa.tf)들에 대해 이 Hub Role이 sts:AssumeRole을
# "호출할" 권한. local.gitops_bridge_spokes(레지스트리 discovery 결과, locals.tf)를 그대로
# 참조해 실제로 등록된 spoke만큼만 스코프를 연다(dev만 등록되어 있으면 dev 하나만, prod가
# 등록되면 자동으로 같이 열림 — 두 곳을 따로 안 맞춰도 됨). Resource ARN은 spoke가 레지스트리에
# 실어 보낸 spoke_role_arn을 그대로 쓴다 — "${cluster_name}-argocd-spoke-irsa" 같은 네이밍
# 패턴을 여기서 다시 조합하지 않는다(gitops-bridge-registry.tf와 동일한 self-service 원칙).
#
# [count 가드] 등록된 spoke가 0개면 위 for 식이 빈 리스트를 만들어 Resource=[]인 IAM
# 정책이 생성 시도되고, AWS가 MalformedPolicyDocument로 거부한다. spoke가 하나도 없으면
# 이 정책 자체가 필요 없으므로 count로 생성을 건너뛴다.
resource "aws_iam_role_policy" "argocd_hub_assume_spokes" {
  count = length(local.gitops_bridge_spokes) > 0 ? 1 : 0

  name = "assume-gitops-bridge-spoke-roles"
  role = aws_iam_role.argocd_application_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeGitopsBridgeSpokeRoles"
        Effect = "Allow"
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [
          for name, spoke in local.gitops_bridge_spokes : spoke.spoke_role_arn
        ]
      }
    ]
  })
}

# argocd-application-controller ServiceAccount는 이미 argo-cd Helm chart(module.eks_addons)가
# 만들어둔다 — 여기서 kubernetes_service_account_v1을 새로 선언하지 않는다. annotation
# (eks.amazonaws.com/role-arn)을 이 SA에 주입하는 작업은 modules/eks-addons/1.0.0의
# argocd_controller_irsa_role_arn 변수(main.tf의 module.eks_addons 호출부 참조)를 통해
# Helm values(controller.serviceAccount.annotations) 경로로 이루어진다.

# monitoring 자기 자신을 가리키는 cluster Secret 데이터.
# server/config는 일부러 넣지 않는다 — vendor 모듈(gitops-bridge-dev/gitops-bridge/helm)이
# cluster.server/cluster.config를 안 받으면 `server = https://kubernetes.default.svc`,
# `config = {tlsClientConfig: {insecure: false}}`로 자동 채운다.
# 이 값이 ArgoCD 자신의 "in-cluster" 개념과 동일해서, 별도 IRSA/Access Entry/RBAC 체인 없이도
# 항상 유효하다 — 위 파일 헤더 참고. 남기는 건 metadata뿐이고, 이건 addon
# ApplicationSet들의 `{{metadata.annotations.xxx}}` 브릿지용으로 여전히 필요하다.
#
# 스키마 근거: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters
#
# [metadata — ApplicationSet cluster generator용 메타데이터 브릿지]
# 공식 gitops-bridge-dev 패턴(https://github.com/gitops-bridge-dev/gitops-bridge)을 따른다:
# Terraform이 만든 addon IAM Role ARN 등을 이 Secret의 K8s object metadata.annotations로
# 기록해두면, ApplicationSet의 `clusters` generator가 이 Secret을 순회하며
# `{{metadata.annotations.lbc_role_arn}}` 같은 템플릿 표현식으로 각 Application에 주입할
# 수 있다. dev/prd를 spoke로 등록하면서 클러스터마다 IAM Role ARN 등의 값이 달라지므로,
# devops-manifest의 addon values-override.yaml에 값을 직접 하드코딩하는 대신 이 브릿지로
# 클러스터별 값을 동적으로 전달한다.
#
# [WHY — 이 local이 kubernetes_secret_v1 리소스가 아니라 module.eks_addons에 넘길 변수인 이유]
# ArgoCD 설치 주체(gitops-bridge-dev/gitops-bridge/helm)가 cluster Secret 생성까지
# 전담한다(modules/eks-addons/2.0.0/main.tf의 module "gitops_bridge_bootstrap" 참고). 그래서
# 이 root는 리소스를 직접 만들지 않고, "Hub 전용 값(root에서만 계산 가능한 것)"만 조립해
# module.eks_addons의 gitops_bridge_hub 변수로 넘긴다. addon별 IRSA Role ARN처럼 그 모듈
# 스스로 이미 계산해둔 값(gitops_metadata)까지 여기서 미리 합쳐 넣으면 "module.eks_addons의
# 출력을 같은 module.eks_addons의 입력으로 되먹이는" 순환 참조가 된다 — 그 merge는 공유
# 모듈 내부(형제 module 참조)에서 이뤄진다(modules/eks-addons/2.0.0/main.tf 참고).
locals {
  gitops_bridge_hub_cluster = {
    cluster_name = "monitoring-self"
    # gitops-bridge-dev/gitops-bridge/helm은 이 값을 생략하면 내부 기본값 "dev"를 cluster
    # Secret의 labels/annotations에 그대로 찍는다(모듈 소스: `environment = try(var.cluster.
    # environment, "dev")`) — dev/prd를 spoke로 등록해 label 셀렉터를 실사용하는 상태에서는
    # monitoring이 dev 전용 템플릿에 잘못 매칭될 수 있어 명시한다.
    environment = "monitoring"
    # server/config는 의도적으로 생략 — 위 파일 헤더 참고(vendor 기본값이 in-cluster로 자동 대체).
    metadata = {
      aws_cluster_name              = local.cluster_name
      aws_region                    = "ap-northeast-2"
      aws_account_id                = data.aws_caller_identity.current.account_id
      vpc_id                        = local.vpc_id
      argocd_image_updater_role_arn = aws_iam_role.argocd_image_updater.arn
      # workload 계정은 "클러스터마다 달라지는 값"은 아니지만(2계정 토폴로지 자체가
      # 프로젝트 상수), 동적으로 받아올 수 있는 값은 하드코딩하지 않는다는 원칙에 따라
      # 이 값도 devops-manifest에 직접 박아넣지 않고 동일한 브릿지로 전달한다 — workload
      # 계정이 바뀌어도 이 값 한 곳만 갱신하면 되고 devops-manifest 코드는 안 건드려도 된다.
      workload_account_id                 = local.workload_account_id
      external_dns_cross_account_role_arn = local.external_dns_cross_account_role_arn
      # bootstrap/root-app-addons.yaml(ApplicationSet)이 '{{metadata.annotations.xxx}}'로
      # 읽는 devops-manifest 저장소 좌표. repoURL을 YAML에 직접 하드코딩하지 않는 이유는
      # workload_account_id와 동일하다 — 저장소 이전·브랜치 전략 변경 시 여기 한 곳만
      # 고치면 된다. workload(catalog/gateway/order) 쪽 동일 필드는 아직 없다.
      addons_repo_url      = "https://github.com/hul0810/eks-practice-devops-manifest.git"
      addons_repo_basepath = "argocd/"
      addons_repo_path     = "applicationsets/eks-addons"
      addons_repo_revision = "main"
    }
  }
}
