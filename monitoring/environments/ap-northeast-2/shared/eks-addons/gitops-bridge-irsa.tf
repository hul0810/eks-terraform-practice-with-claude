################################################################################
# GitOps Bridge Hub — argocd-application-controller IRSA
#
# [정정 — 2026-07-21, Phase 6-1의 Access Entry+RBAC 체인 제거]
# 원래 이 파일은 IAM Role + EKS Access Entry + K8s ClusterRole(RBAC) 3단계 체인으로
# monitoring 자기 자신을 awsAuthConfig 방식으로 "명시 등록"해서, 그 인증 경로가 실제로
# 동작하는지 검증하는 Phase 6-1 실습이었다(과거 버전은 git 이력 참고). 이후
# `bootstrap/root-app-addons.yaml`을 포함해 monitoring 자신을 대상으로 하는 모든
# ApplicationSet이 `destination: name: in-cluster`(ArgoCD 자신의 내장 ServiceAccount
# 권한, awsAuthConfig 경로를 아예 안 씀)로 굳어지면서 이 Access Entry+RBAC 체인이
# 실제로 쓰이는 경로가 사라졌다 — CloudTrail에 이 Role로 monitoring 자신의 EKS API에
# 접근한 기록이 전혀 없고, application-controller 로그에도 monitoring-self 클러스터
# 엔드포인트가 등장하지 않는 것으로 실측 확인했다. vendor 모듈
# (gitops-bridge-dev/gitops-bridge/helm) 소스를 보면 cluster.server/cluster.config를
# 아예 안 넘기면 `server = https://kubernetes.default.svc`, `config = {tlsClientConfig:
# {insecure: false}}`(awsAuthConfig 없음)로 자동 대체된다 — 애초에 monitoring 자신을
# 위해 이 인증 체인을 직접 만들 필요가 없었다. 그래서 Access Entry+RBAC 3개 리소스를
# 제거하고, cluster Secret도 vendor 기본값을 그대로 쓰도록 server/config를 뺐다(아래
# local.gitops_bridge_hub_cluster 참고). 남겨두는 건 이 IAM Role 하나뿐 — 이유는 아래.
#
# [이 Role이 여전히 필요한 이유 — Phase 6-5 크로스 계정 spoke assume]
# 이 Role은 monitoring 자신을 위해서가 아니라, Hub가 dev/prd(workload 계정) spoke
# 클러스터를 원격 관리하기 위한 크로스 계정 identity로 쓰인다 — argocd-application-controller
# 파드가 이 Role을 IRSA로 assume한 뒤, 그 신원으로 dev/prd 각각의 spoke Role
# (gitops-bridge-spoke-irsa.tf)을 추가로 sts:AssumeRole한다(아래
# aws_iam_role_policy.argocd_hub_assume_spokes). 즉 "OIDC federated principal이 STS로
# 신원을 증명한다"는 역할만 남고, monitoring 자신에 대한 K8s 인가(RBAC)는 더 이상 이
# 파일의 책임이 아니다.
################################################################################

# [정정 — 2026-07-21, Phase 6-5에서 발견] "이 Role엔 신뢰 정책만 있고 권한 정책은 없다"는
# 아래 문단은 monitoring-self(같은 계정 Access Entry) 케이스에만 맞는 말이었다. dev/prd
# 같은 크로스 계정 spoke를 awsAuthConfig.roleARN으로 등록하려면 이 Role이 그 계정의
# spoke Role을 sts:AssumeRole로 불러올 권한이 별도로 필요하다 — 신뢰 정책(대상 Role 쪽에서
# "누가 나를 assume할 수 있는가")과 권한 정책(이 Role 쪽에서 "내가 무엇을 assume할 수
# 있는가")은 양방향으로 각각 허용돼야 하는 별개의 정책이다. 이 사실을 몰라서 처음엔 신뢰
# 정책만 만들고 넘어갔다가, 실제 dev spoke 등록 테스트에서
# `AccessDenied: ... not authorized to perform: sts:AssumeRole on resource: ...` 로 실패한
# 뒤에야 발견했다 — 아래 aws_iam_role_policy.argocd_hub_assume_spokes가 그 보충이다.
#
# STS AssumeRoleWithWebIdentity(OIDC federation) 자체는 별도 IAM 권한(inline policy)이
# 필요 없다 — 이 Role은 "누가 이 신원인지"만 증명하는 용도이고, 실제로 쓰는 권한은 아래
# aws_iam_role_policy.argocd_hub_assume_spokes(dev/prd spoke Role을 assume하는 권한)뿐이다.
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

# [Phase 6-5 — 크로스 계정 spoke assume 권한]
# gitops-bridge-spokes.tf가 만드는 spoke Role(project/environments/{develop,production}/
# .../eks-addons/gitops-bridge-spoke-irsa.tf)들에 대해 이 Hub Role이 sts:AssumeRole을
# "호출할" 권한. spoke Role 쪽 신뢰 정책(누가 나를 assume할 수 있는가)만으로는 부족하고,
# 이 Role 쪽에도 "내가 무엇을 assume할 수 있는가"를 별도로 허용해야 한다 — 위 [정정] 참고.
# local.enabled_gitops_bridge_spokes를 그대로 참조해 활성화된 spoke만큼만 스코프를 연다
# (dev만 켜져 있으면 dev 하나만, prd를 켜면 자동으로 같이 열림 — 두 곳을 따로 안 맞춰도 됨).
#
# [count 가드 — terraform-reviewer 지적, 2026-07-21] 활성화된 spoke가 0개가 되면(예: dev도
# /env-teardown으로 내려간 뒤 gitops_bridge_spokes에서 enabled=false로 바꾸는 시점) 위
# for 식이 빈 리스트를 만들어 Resource=[]인 IAM 정책이 생성 시도된다 — AWS가
# MalformedPolicyDocument로 거부한다. spoke가 하나도 없으면 이 정책 자체가 필요 없으므로
# count로 생성을 건너뛴다.
resource "aws_iam_role_policy" "argocd_hub_assume_spokes" {
  count = length(local.enabled_gitops_bridge_spokes) > 0 ? 1 : 0

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
          for name, spoke in local.enabled_gitops_bridge_spokes :
          "arn:aws:iam::${local.workload_account_id}:role/${spoke.aws_cluster_name}-argocd-spoke-irsa"
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
# `config = {tlsClientConfig: {insecure: false}}`로 자동 채운다(모듈 소스 확인, 2026-07-21).
# 이 값이 ArgoCD 자신의 "in-cluster" 개념과 동일해서, 별도 IRSA/Access Entry/RBAC 체인 없이도
# 항상 유효하다 — 위 파일 헤더의 "정정" 참고. 남기는 건 metadata뿐이고, 이건 addon
# ApplicationSet들의 `{{metadata.annotations.xxx}}` 브릿지용으로 여전히 필요하다.
#
# 스키마 근거: https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#clusters
#
# [metadata — ApplicationSet cluster generator용 메타데이터 브릿지]
# 공식 gitops-bridge-dev 패턴(https://github.com/gitops-bridge-dev/gitops-bridge)이 쓰는
# 방식 그대로: Terraform이 만든 addon IAM Role ARN 등을 이 Secret의 K8s object
# metadata.annotations로 기록해두면, ApplicationSet의 `clusters` generator가 이 Secret을
# 순회하며 `{{metadata.annotations.lbc_role_arn}}` 같은 템플릿 표현식으로 각 Application에
# 주입할 수 있다. 이전에는 이 annotation이 비어 있어서(awsAuthConfig만 있었음) devops-manifest의
# 각 addon values-override.yaml에 ARN을 직접 하드코딩했는데, 이건 monitoring처럼 클러스터가
# 1개뿐이고 이름이 고정(role_name_use_prefix=false)이라 우연히 문제가 안 됐을 뿐 구조적으로
# 안전한 방식이 아니었다(Karpenter clusterEndpoint 하드코딩 사고가 그 증거 — 값이 우연히
# 안정적이지 않으면 바로 깨진다). 6-5(dev/prd를 spoke로 등록)부터는 클러스터마다 값이
# 달라지므로 이 브릿지가 필수가 된다 — 지금 미리 갖춰서 그때 가서 10개 Application을 통째로
# 다시 쓰는 일을 피한다.
#
# [WHY — 이 local이 kubernetes_secret_v1 리소스가 아니라 module.eks_addons에 넘길 변수인 이유]
# 원래는 여기서 직접 kubernetes_secret_v1을 선언했지만, ArgoCD 설치 주체를
# gitops-bridge-dev/gitops-bridge/helm으로 바꾸면서 그 모듈이 cluster Secret 생성까지
# 전담하게 됐다(modules/eks-addons/2.0.0/main.tf의 module "gitops_bridge_bootstrap" 참고).
# 그래서 이 root는 이제 리소스를 직접 만들지 않고, "Hub 전용 값(root에서만 계산 가능한 것)"만
# 조립해 module.eks_addons의 gitops_bridge_hub 변수로 넘긴다. addon별 IRSA Role ARN처럼
# 그 모듈 스스로 이미 계산해둔 값(gitops_metadata)까지 여기서 미리 합쳐 넣지 않는 이유는,
# 그러면 "module.eks_addons의 출력을 같은 module.eks_addons의 입력으로 되먹이는" 순환
# 참조가 되기 때문이다(직접 겪은 실수 — 상세는 modules/eks-addons/2.0.0/main.tf의 module
# "gitops_bridge_bootstrap" 상단 주석 참고). 그 merge는 공유 모듈 내부(형제 module 참조)에서
# 이뤄진다.
locals {
  gitops_bridge_hub_cluster = {
    cluster_name = "monitoring-self"
    # [리뷰에서 발견 — environment 누락 시 벤더 기본값 "dev"로 라벨링됨]
    # gitops-bridge-dev/gitops-bridge/helm은 이 값을 생략하면 내부 기본값 "dev"를 cluster
    # Secret의 labels/annotations에 그대로 찍는다(모듈 소스: `environment = try(var.cluster.
    # environment, "dev")`). 지금은 apps={}라 ApplicationSet cluster generator가 이 라벨을
    # 셀렉터로 안 쓰고 있어 드러나지 않지만, 6-5(dev/prd를 spoke로 등록하며 label 셀렉터를
    # 실사용하기 시작하는 단계)에서는 monitoring이 dev 전용 템플릿에 잘못 매칭될 수 있다 —
    # 그 전에 명시해 이 클래스의 버그를 원천 차단한다.
    environment = "monitoring"
    # server/config는 의도적으로 생략 — 위 파일 헤더 참고(vendor 기본값이 in-cluster로 자동 대체).
    metadata = {
      aws_cluster_name              = local.cluster_name
      aws_region                    = "ap-northeast-2"
      aws_account_id                = data.aws_caller_identity.current.account_id
      vpc_id                        = local.vpc_id
      argocd_image_updater_role_arn = aws_iam_role.argocd_image_updater.arn
      # workload 계정은 "클러스터마다 달라지는 값"은 아니지만(2계정 토폴로지 자체가
      # 프로젝트 상수), 이 값도 Terraform이 소유한 값을 devops-manifest에 하드코딩하는
      # 대신 동일한 브릿지로 전달하는 게 "동적으로 받아올 수 있으면 하드코딩하지 않는다"
      # 원칙에 맞다 — workload 계정이 바뀌거나(계정 이전 등) 제3의 계정이 추가되는
      # 경우에도 이 값 하나만 갱신하면 되고 devops-manifest 쪽 코드는 안 건드려도 된다.
      workload_account_id                 = local.workload_account_id
      external_dns_cross_account_role_arn = local.external_dns_cross_account_role_arn
      # bootstrap/root-app-addons.yaml(ApplicationSet)이 '{{metadata.annotations.xxx}}'로 읽는
      # devops-manifest 저장소 좌표. repoURL 자체를 YAML에 하드코딩하지 않는 이유: 이 값도
      # 저장소 이전·조직 변경·브랜치 전략 변경으로 바뀔 수 있는 값이라 위 workload_account_id와
      # 동일한 원칙을 적용한다 — 바뀌면 여기 한 곳만 고치면 되고 bootstrap YAML은 손댈 필요 없다.
      # workload(catalog/gateway/order) 쪽 동일 필드는 아직 안 만든다 — main.tf의
      # gitops_bridge_hub WHY 참고(Phase 6-6에서 별도 결정).
      addons_repo_url      = "https://github.com/hul0810/eks-practice-devops-manifest.git"
      addons_repo_basepath = "argocd/"
      addons_repo_path     = "applicationsets/eks-addons"
      addons_repo_revision = "main"
    }
  }
}
