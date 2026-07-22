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
# false}}`(awsAuthConfig 없음)로 자동 대체한다(local.gitops_bridge_hub_cluster — locals.tf 참고).
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
#
# monitoring 자기 자신을 가리키는 cluster Secret 데이터(local.gitops_bridge_hub_cluster)는
# locals.tf에 있다 — root-level local은 리소스 파일에 분산하지 않고 locals.tf에 집중한다
# (docs/project-structure.md 참조).
