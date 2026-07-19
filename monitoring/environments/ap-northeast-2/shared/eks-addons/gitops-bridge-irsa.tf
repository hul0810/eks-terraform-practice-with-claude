################################################################################
# GitOps Bridge Hub — ArgoCD application-controller IRSA + Access Entry + RBAC
#
# [배경 — Phase 6-1]
# monitoring 계정(157325288431, eks-practice-mon 클러스터)의 ArgoCD를 GitOps Bridge Hub로
# 사용하기 위해, ArgoCD가 클러스터를 awsAuthConfig 방식으로 명시 등록하려면 AWS IAM 인증이
# 필요하다. 지금 argocd-application-controller ServiceAccount에는 IAM Role이 전혀 붙어있지
# 않다(라이브 확인: `kubectl get serviceaccount -n argocd`에서 관련 annotation 없음).
#
# [3단계 체인 — 왜 세 리소스가 함께 필요한가]
# AWS IAM 인증(STS)과 Kubernetes 인가(RBAC)는 서로 다른 계층이라 IAM Role 하나만으로는
# K8s API에 대한 어떤 권한도 생기지 않는다. 이 파일은 그 둘을 잇는 다리를 놓는다:
#   1. aws_iam_role                    : OIDC federated principal이 STS로 신원을 증명
#   2. aws_eks_access_entry            : EKS가 그 IAM 신원을 인식하고 K8s Group에 매핑
#   3. kubernetes_cluster_role(_binding): 그 Group에 실제 K8s 권한(RBAC)을 부여
# 2번(Access Entry)이 없으면 IAM 인증에는 성공해도 K8s API는 "인가되지 않은 사용자"로
# 취급한다 — Karpenter 노드 IAM Role의 aws_eks_access_entry.karpenter_node
# (modules/eks-addons/1.0.0/main.tf)와 정확히 동일한 메커니즘이다(대상만 노드 vs 파드 신원).
#
# 참고: https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html
#       https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html
#
# [왜 AWS 관리형 정책을 쓰지 않고 커스텀 ClusterRole을 만드는가]
# - AmazonEKSClusterAdminPolicy(cluster-admin 동급): 공식 문서가 "convenient for development
#   and POCs but should not be used in production"이라 명시 — 이번 작업에서 배제.
# - AmazonEKSViewPolicy(관리형 읽기 전용): 커버하는 API 그룹이 고정 목록(apps, autoscaling,
#   batch 등)뿐이라 CRD(apiextensions.k8s.io)나 커스텀 리소스를 전혀 커버하지 않는다. 이
#   클러스터는 Karpenter(karpenter.sh), ArgoCD 자신(argoproj.io), External Secrets
#   (external-secrets.io) 등 CRD 기반 리소스 비중이 커서 이 정책만으로는 부족하다.
# - AmazonEKSAdminViewPolicy: API 그룹 "*"/리소스 "*"/verb get,list,watch로 CRD까지
#   커버하지만, 공식 문서가 "Kubernetes Secrets까지 전체 노출"된다고 명시적으로 경고한다.
#   이번엔 리소스 범위는 전체로 열되 Secrets 노출 범위는 직접 판단하고 싶어 AWS 관리형
#   정책 대신 커스텀 ClusterRole을 쓴다 — 공식 문서의 "Production setup with least
#   privilege" 섹션이 정확히 이 방식을 예시로 제공한다.
#
# [왜 이번 단계엔 쓰기 권한이 없는가]
# Phase 6-1(클러스터 등록 실습) 단계에서는 아직 아무 워크로드도 이 Hub를 통해 배포하지
# 않으므로 읽기 전용(get/list/watch)이면 충분하다. 쓰기 권한(예: 특정 네임스페이스로
# 스코프한 AmazonEKSEditPolicy)은 실제 애드온을 이 Hub로 옮기는 Phase 6-2 이후 그때그때
# 추가한다 — 이번 범위에는 포함하지 않는다(사용자와 합의된 범위 제한).
################################################################################

# STS AssumeRoleWithWebIdentity 자체는 별도 IAM 권한(inline policy)이 필요 없다 — 이 Role은
# "누가 이 신원인지"만 증명하는 용도이고, 실제 K8s API 권한은 전부 아래 Access Entry +
# ClusterRoleBinding(RBAC)이 부여한다. 따라서 이 Role에는 신뢰 정책만 있고 권한 정책은 없다.
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

# argocd-application-controller ServiceAccount는 이미 argo-cd Helm chart(module.eks_addons)가
# 만들어둔다 — 여기서 kubernetes_service_account_v1을 새로 선언하지 않는다. annotation
# (eks.amazonaws.com/role-arn)을 이 SA에 주입하는 작업은 modules/eks-addons/1.0.0의
# argocd_controller_irsa_role_arn 변수(main.tf의 module.eks_addons 호출부 참조)를 통해
# Helm values(controller.serviceAccount.annotations) 경로로 이루어진다.

# AWS 인증(STS)과 K8s 인가(RBAC)는 별개 계층이며, Access Entry가 그 둘을 잇는 다리다.
# Access Entry가 없으면 위 IAM Role로 STS 인증에 성공해도 EKS API 서버는 이 신원을
# 인가되지 않은 사용자로 취급해 전부 거부한다. Karpenter 노드용
# aws_eks_access_entry.karpenter_node(modules/eks-addons/1.0.0/main.tf)와 동일한 메커니즘 —
# 그쪽은 EC2 노드 IAM Role을 system:nodes/system:bootstrappers 그룹에 매핑하고, 이쪽은
# ArgoCD 파드 IRSA Role을 아래 커스텀 ClusterRole에 매핑한다는 점만 다르다.
#
# [정정 — kubernetes_groups를 명시해야 하는 이유]
# 처음엔 "eks-access-entry:<principal-arn>" 형식의 K8s Group이 Access Entry 생성만으로
# 자동 부여되는 줄 알았으나(AWS 공식 문서 예시를 잘못 해석), 실제로는 그 예시가 AWS의
# 완전관리형 "EKS Capability for Argo CD" 기능 전용 동작이었다. 우리처럼 STANDARD 타입
# Access Entry를 직접 만들 때는 kubernetes_groups를 명시하지 않으면 그룹이 전혀 배정되지
# 않는다 — 인증된 신원은 세션마다 바뀌는 assumed-role 사용자명(User)만 갖고 어떤 Group에도
# 속하지 않아, 아래 ClusterRoleBinding(Group 대상)이 매칭할 대상이 없어 전부 forbidden
# 처리된다(라이브에서 직접 확인: `aws eks describe-access-entry`의 kubernetesGroups가 빈
# 배열이었고, 실제 신원은 User("arn:...assumed-role/.../<SessionName>")로만 인증됨).
# User kind로 직접 바인딩하지 않는 이유는 SessionName이 매 assume마다 바뀌어 재현성이
# 없기 때문이다 — kubernetes_groups로 세션과 무관한 안정적인 식별자를 명시해야 한다.
#
# [Group 이름을 ARN 전체가 아니라 짧은 커스텀 이름으로 쓰는 이유]
# kubernetes_groups 값은 63자 제한이 있다(라이브 적용 시 InvalidParameterException으로 확인 —
# "eks-access-entry:<ARN 전체>"는 80자라 거부됨). AWS 문서의 "eks-access-entry:" 접두사는
# 그 관리형 기능이 내부적으로 붙이는 값일 뿐, 우리가 STANDARD Access Entry에서 그 형식을
# 그대로 흉내 낼 필요가 없다 — kubernetes_groups와 ClusterRoleBinding의 subject.name만
# 서로 일치하면 이름은 우리가 임의로 정해도 된다. 짧고 뜻이 드러나는 이름을 쓴다.
resource "aws_eks_access_entry" "argocd_hub_self" {
  cluster_name      = local.cluster_name
  principal_arn     = aws_iam_role.argocd_application_controller.arn
  type              = "STANDARD"
  kubernetes_groups = ["argocd-hub-readers"]

  tags = local.common_tags
}

# RBAC는 K8s 빌트인 타입이라 kubernetes_manifest와 달리 plan 시점에 CRD 스키마를 조회하지
# 않는다 — main.tf의 ExternalSecret/SecretStore 리소스들과 달리 2단계 apply 제약이 없다.
#
# 리소스는 전체(*)로 열되 verb는 get/list/watch만 허용한다 — 이번 단계는 읽기 전용이면
# 충분하고(위 "왜 이번 단계엔 쓰기 권한이 없는가" 참조), Secrets를 포함해 리소스 범위를
# 넓게 열어야 CRD(karpenter.sh, argoproj.io, external-secrets.io 등)까지 빠짐없이 조회할 수
# 있다. Secrets 노출은 이 ClusterRole을 어떤 Group에 바인딩하는지(아래
# kubernetes_cluster_role_binding)로 통제한다 — 지금은 이 IRSA Role 하나에만 바인딩된다.
resource "kubernetes_cluster_role" "argocd_read_all" {
  metadata {
    name = "argocd-hub-read-all"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }
}

# subjects.name은 위 aws_eks_access_entry.argocd_hub_self의 kubernetes_groups와 정확히
# 일치해야 한다 — EKS가 자동으로 만들어주는 예약된 이름이 아니라(위 aws_eks_access_entry
# 주석 참조), 우리가 두 리소스 양쪽에 동일하게 지정한 임의의 이름이다.
resource "kubernetes_cluster_role_binding" "argocd_read_all" {
  metadata {
    name = "argocd-hub-read-all"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argocd_read_all.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "argocd-hub-readers"
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [aws_eks_access_entry.argocd_hub_self]
}

# monitoring 자기 자신을 가리키는 cluster Secret 데이터 — GitOps Bridge 실습(6-1)용.
# ArgoCD는 파드가 뜬 클러스터를 "in-cluster"로 암묵 등록하지만(server=https://kubernetes.default.svc),
# 그건 K8s 자체 ServiceAccount 토큰 인증이라 awsAuthConfig 경로를 타지 않는다. 여기서는 일부러
# 같은 클러스터를 별도 이름(monitoring-self)으로 "명시 등록"해서, 위에서 만든 IRSA+Access
# Entry+RBAC 체인이 실제로 동작하는지(=AWS 인증 경로로 K8s API에 접근 가능한지) 검증한다.
#
# server/caData는 새 값이 아니라 Terraform이 이미 갖고 있는 EKS 클러스터 output을 그대로
# 재사용한다(locals.tf의 cluster_endpoint/cluster_certificate_authority_data).
# roleARN은 넣지 않는다 — 크로스 계정이 아니라 이 IRSA Role이 이미 이 클러스터에 직접
# Access Entry로 접근 권한을 가지므로 별도로 assume할 Role이 없다(cross-account용 roleARN은
# 6-5에서 workload 계정 dev/prd를 등록할 때 필요해진다).
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
    server      = local.cluster_endpoint
    config = jsonencode({
      awsAuthConfig = {
        clusterName = local.cluster_name
      }
      tlsClientConfig = {
        caData = local.cluster_certificate_authority_data
      }
    })
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
    }
  }
}
