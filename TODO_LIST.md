# EKS 인프라 구축 TODO LIST

## 진행 상황 범례
- [ ] 미완료
- [x] 완료
- [~] 진행 중

---

## Git 태그 전략

이 프로젝트는 단계별 완성본을 Git 태그로 기록한다.
각 태그는 "무엇을 달성한 구성인가"를 이름만으로 파악할 수 있도록 명명한다.

| 태그 | 달성 단계 | 설명 |
|------|----------|------|
| `foundation/single-account-eks` | 1단계(Phase 1~6) 완료 시 | 단일 계정, dev/prd 2클러스터, GitOps·Observability 포함 기초 구성 |
| `enterprise/hub-spoke-eks` | 2단계(Phase 7~11) 완료 시 | 2계정(intra/workload), TGW, Hub-Spoke ArgoCD·Observability, 보안 거버넌스 |

---

## 1단계: 기초 구성 (단일 계정, 비용 최소화)

> **목표**: dev + production 2환경에 EKS 클러스터, GitOps(ArgoCD), Observability(Prometheus + Grafana)를 구축한다.
> 실무 기준에서 의도적으로 단순화한 항목은 `CLAUDE.md` 비용 예외 항목 참조.
> 이 단계 완료 시 태그: `foundation/single-account-eks`

---

## Phase 1. 원격 상태 저장소 구성

> `global/tfstate-backend/` 디렉토리

- [x] `global/tfstate-backend/providers.tf` 작성 (AWS provider 설정)
- [x] `global/tfstate-backend/main.tf` 작성
  - [x] S3 버킷 생성 (버전 관리 + SSE-S3 암호화 + public access 차단)
  - [x] State Lock: S3 네이티브 락(`use_lockfile = true`, Terraform 1.10+) 적용 — DynamoDB 락 테이블 불필요
- [x] `global/tfstate-backend/outputs.tf` 작성 (버킷명, 버킷 ARN 출력)

---

## Phase 2. 모듈 + 환경 구성 (dev)

> 각 모듈 작성 단계마다 `environments/develop/`에 해당 모듈 호출 코드를 함께 추가한다.

### 2-1. modules/vpc + environments/dev vpc 구성

- [x] `modules/vpc/variables.tf` 작성
  - [x] vpc_cidr, azs, public/private/database/tgw 서브넷, single_nat_gateway, cluster_name 변수 정의
  - [x] 변수 validation 블록 추가 (CIDR 형식, AZ 최소 2개)
- [x] `modules/vpc/main.tf` 작성
  - [x] `terraform-aws-modules/vpc v6.6.1` 호출
  - [x] Public 서브넷 (ALB, NAT GW용)
  - [x] Private 서브넷 (EKS 노드용)
  - [x] Database 서브넷 (RDS, ElastiCache용)
  - [x] TGW 서브넷 (Transit Gateway 어태치먼트용, intra 타입 활용)
  - [x] NAT Gateway 단일/다중 AZ 변수 토글 (`single_nat_gateway`, `enable_nat_gateway`)
  - [x] S3 Gateway Endpoint (`aws_vpc_endpoint` 별도 리소스)
- [x] `modules/vpc/outputs.tf` 작성 (vpc_id, subnet_ids 4종, route_table_ids, nat_public_ips)
- [x] `environments/develop/ap-northeast-2/shared/vpc/providers.tf` 작성 (AWS provider + AssumeRole)
- [x] `environments/develop/ap-northeast-2/shared/vpc/backend.tf` 작성 (key: dev/ap-northeast-2/shared/vpc/terraform.tfstate)
- [x] `environments/develop/ap-northeast-2/shared/vpc/locals.tf` 작성 (VPC CIDR 10.10.0.0/16, 서브넷 4종, 4개 AZ 기준)
- [x] `environments/develop/ap-northeast-2/shared/vpc/data.tf` 작성 (`aws_availability_zones` 동적 조회)
- [x] `environments/develop/ap-northeast-2/shared/vpc/main.tf` 작성 (vpc 모듈 호출)
- [x] `environments/develop/ap-northeast-2/shared/vpc/outputs.tf` 작성 (vpc 출력값 노출)

### 2-2. modules/eks + environments/dev eks 추가

- [x] `modules/vpc/main.tf`에 ELB 서브넷 태그 추가
  - [x] Public 서브넷: `kubernetes.io/role/elb = "1"`
  - [x] Private 서브넷: `kubernetes.io/role/internal-elb = "1"`
- [x] `modules/eks/variables.tf` 작성
- [x] `modules/eks/main.tf` 작성
  - [x] `terraform-aws-modules/eks v21.22.0` 호출 (v21.20.0 → v21.22.0 최신 버전 적용)
  - [x] 엔드포인트 설정 (dev: Public+Private / prd: Private only)
  - [x] 컨트롤 플레인 로깅 on/off 변수화 (CloudWatch 비용 제어, 기본 비활성화)
  - [x] 시스템용 Managed Node Group 구성 (Karpenter 실행용)
    - [x] Taint: `CriticalAddonsOnly=true:NoSchedule`
    - [x] Label: `role: system`
    - [x] `lifecycle { create_before_destroy = true }` 적용 (모듈 내부 하드코딩 확인)
  - [x] Security Group Rule을 인라인 대신 별도 리소스로 분리
    - [x] `aws_vpc_security_group_ingress_rule`
    - [x] `aws_vpc_security_group_egress_rule`
  - [x] `cluster_addons` 블록 추가 (bootstrap add-on 3종)
    - [x] `vpc-cni` (`before_compute = true`: 노드 그룹 생성 전 CNI 먼저 배포)
    - [x] `kube-proxy`
    - [x] `coredns`
- [x] `modules/eks/outputs.tf` 작성 (cluster_name, endpoint 등, oidc_provider_arn 포함)
- [x] `environments/develop/ap-northeast-2/shared/eks/` 디렉토리 생성 및 구성 파일 작성
  - [x] `providers.tf`, `backend.tf`, `data.tf`, `locals.tf`, `main.tf`, `outputs.tf`
  - [x] EKS 클러스터 생성 완료

### 2-3. modules/eks-addons + environments/dev eks-addons 추가

> **아키텍처**: 분리 root module 패턴 (Option C)
> - `environments/.../eks/` — 클러스터 state (완성, 변경 없음)
> - `environments/.../eks-addons/` — 애드온 state (신규, `terraform_remote_state.eks` 참조)
> - Helm provider: `data "aws_eks_cluster"` data source로 초기화 (2단계 apply 불필요)
>
> **순서 중요**: eks-pod-identity-agent는 modules/eks(2-2)에서 이미 설치됨. 중복 선언 금지.
> 전략: 관리형 우선 (`docs/addon-strategy.md` 참조)

- [x] `modules/eks-addons/1.0.0/variables.tf` 작성
- [x] `modules/eks-addons/1.0.0/main.tf` 작성 — **Pod Identity 전략**
  - [x] 각 섹션에 blueprints 미사용 이유 주석 명시 (Pod Identity vs IRSA 선택 근거)
  - [x] **EKS 관리형 (`aws_eks_addon` + Pod Identity IAM)**
    - [x] `aws-ebs-csi-driver` v1.60.1-eksbuild.1 — IAM: `AmazonEBSCSIDriverPolicy`
    - [x] `metrics-server` v0.8.1-eksbuild.10 — IAM 불필요
    - [x] `external-dns` v0.21.0-eksbuild.4 — IAM: Route53 권한 (조건부, `enable_external_dns`)
  - [x] **Helm 전용 (`aws-ia/eks-blueprints-addons ~> 1.23.0`)**
    - [x] `enable_aws_load_balancer_controller = true` — 관리형 addon 없어 blueprints IRSA 예외 사용
    - ~~`enable_kube_prometheus_stack`~~ — Observability는 Phase 6으로 이동
- [x] `modules/eks-addons/1.0.0/outputs.tf` 작성
- [x] `modules/eks-addons/1.0.0/CLAUDE.md` 작성
- [x] `modules/eks-addons-pod-identity/1.0.0/` 작성 — **Pod Identity 전용 구현** (비교 참조용, 배포 X)
  - [x] `variables.tf` — `oidc_provider_arn` 없음, `vpc_id` 추가 (LBC Helm values용)
  - [x] `main.tf` — 모든 애드온(EBS CSI, External DNS, **LBC 포함**)을 Pod Identity로만 구현
    - [x] LBC: `helm_release` 직접 사용 + `aws_eks_pod_identity_association` — blueprints 없음
    - [x] LBC IAM 정책: Statement를 기능별로 그룹화하여 인라인 작성
    - [x] Helm values에 `serviceAccount.annotations.eks.amazonaws.com/role-arn` 미설정 (Pod Identity 특징)
  - [x] `outputs.tf`
  - [x] `modules/eks-addons/1.0.0/`(blueprints 혼합)과의 차이점을 주석으로 비교 문서화
- [x] `environments/develop/ap-northeast-2/shared/eks-addons/` 신규 root module 생성
  - [x] `backend.tf` — key: `project/develop/ap-northeast-2/shared/eks-addons/terraform.tfstate`
  - [x] `providers.tf` — aws + helm + kubernetes (data "aws_eks_cluster" 경유)
  - [x] `data.tf` — `terraform_remote_state.eks` + `data.aws_eks_cluster.this`
  - [x] `locals.tf` — 클러스터 정보, 애드온 버전 집중 관리
  - [x] `main.tf` — `module "eks_addons"` 호출
  - [x] `outputs.tf`
- [x] `terraform plan` 검토
- [x] `terraform apply` 실행 — EBS CSI, Metrics Server, External DNS, LBC 배포 완료

### 2-4. Karpenter NodePool & EC2NodeClass 구성

> **전제**: 2-3 완료 (Karpenter 컨트롤러·IAM Role·SQS·EventBridge는 eks-addons blueprints에서 이미 설치 완료)
> EC2NodeClass / NodePool은 Kubernetes 리소스이므로 eks-addons state 내 별도 파일로 관리한다.
> (`modules/eks-addons/1.0.0/CLAUDE.md` — "NodeClass / NodePool" 섹션 참조)

- [x] `modules/vpc/variables.tf`에 `cluster_name` variable 추가
- [x] `modules/vpc/main.tf`에 Private 서브넷 Karpenter 탐색 태그 추가
  - [x] `"karpenter.sh/discovery" = var.cluster_name`
- [x] `environments/develop/ap-northeast-2/shared/eks-addons/karpenter.tf` 작성
  - [x] `EC2NodeClass` 정의
    - [x] AMI Family: AL2023
    - [x] subnetSelectorTerms: `karpenter.sh/discovery = cluster_name` 태그 탐색
    - [x] securityGroupSelectorTerms: `karpenter.sh/discovery = cluster_name` 태그 탐색
  - [x] `NodePool` 정의
    - [x] instanceCategory: c / m / r 계열
    - [x] dev: Spot 우선 + On-Demand 혼합 (`capacity_type: [spot, on-demand]`)
    - [x] disruption: consolidationPolicy=WhenEmptyOrUnderutilized, consolidateAfter=30s
- [x] `terraform plan` 검토
- [x] `terraform apply` 실행
- [x] `kubectl get ec2nodeclass` — NodeClass 등록 확인
- [x] `kubectl get nodepool` — NodePool 등록 확인
- [x] 테스트 Deployment 배포 후 Karpenter 앱 노드 프로비저닝 확인

### 2-5. modules/ecr + environments/dev ecr 추가

> **목적**: EKS 위에 애플리케이션 배포를 위한 컨테이너 이미지 저장소 구성
> 리포지토리 이름 패턴: `{project}-{service}-{environment}` (예: `eks-practice-api-gateway-develop`)
> State 분리: ECR은 EKS와 독립적 lifecycle이므로 별도 root module로 관리
> MSA 서비스별로 root module을 분리한다 (`{service}/ecr/`) — 단일 `msa/ecr`(1개 리포지토리 통합 관리)는 폐기

- [x] `modules/ecr/1.0.0/variables.tf` 작성 — `repositories` map(object) 입력 변수
- [x] `modules/ecr/1.0.0/main.tf` 작성 — `terraform-aws-modules/ecr ~> 3.2.0` for_each 호출
  - [x] lifecycle policy: 태그 없는 이미지 14일 후 삭제 (priority 1), 최신 10개 유지 (priority 2)
  - [x] image_tag_mutability: IMMUTABLE (기본값)
  - [x] scan_on_push: true (ECR Basic 스캔, 무료)
  - [x] encryption_type: AES256 (dev 비용 절감, prd는 KMS로 변경)
- [x] `modules/ecr/1.0.0/outputs.tf` 작성 (repository_urls, repository_arns 맵)
- [x] `modules/ecr/1.0.0/CLAUDE.md` 작성
- [x] `environments/develop/ap-northeast-2/api-gateway/ecr/` 신규 root module 생성
  - [x] `backend.tf` — key: `project/develop/ap-northeast-2/api-gateway/ecr/terraform.tfstate`
  - [x] `providers.tf`, `data.tf`
  - [x] `locals.tf` — repositories 맵 (`eks-practice-api-gateway-develop`)
  - [x] `main.tf` — `module "ecr"` 호출
  - [x] `outputs.tf`
- [x] `environments/develop/ap-northeast-2/order/ecr/` 신규 root module 생성 (`eks-practice-order-develop`)
- [x] `environments/develop/ap-northeast-2/catalog/ecr/` 신규 root module 생성 (`eks-practice-catalog-develop`)
- [x] `terraform plan` 검토 — 3개 root module 각각 ECR 리포지토리 1개 + lifecycle policy 1개 생성 예정 확인
- [x] `terraform apply` 실행 — 3개 리포지토리 생성 완료
- [x] `terraform plan` 재실행 — 코드와 실제 인프라 일치(변경 없음) 확인

---

## Phase 3. 환경 구성 (prd)

> dev와 동일한 모듈(`modules/vpc/1.0.0`, `modules/eks/1.0.0`, `modules/eks-addons/1.0.0`)을 재사용하여
> `environments/production/ap-northeast-2/shared/`에 동일 패턴의 root module 3종을 구성한다.

### 3-1. modules/vpc 재사용 + environments/production vpc 구성

- [x] `environments/production/ap-northeast-2/shared/vpc/` 신규 root module 생성
  - [x] `backend.tf` — key: `project/production/ap-northeast-2/shared/vpc/terraform.tfstate`
  - [x] `providers.tf`, `data.tf`, `outputs.tf`, `main.tf` (dev와 동일 패턴)
  - [x] `locals.tf`
    - [x] VPC CIDR: `10.11.0.0/16` (dev와 동일한 서브넷 타입별 그룹화 패턴 적용)
    - [x] `azs = data.aws_availability_zones.available.names` (동적 조회)
    - [x] `enable_nat_gateway = true`, `single_nat_gateway = false` (prd는 AZ당 1개 NAT GW)
    - [x] `cluster_name = "eks-practice-production"` (Karpenter 탐색 태그)
- [x] `terraform fmt` + `terraform validate`
- [x] `terraform plan` 검토

### 3-2. modules/eks 재사용 + environments/production eks 구성

- [x] `environments/production/ap-northeast-2/shared/eks/` 신규 root module 생성
  - [x] `backend.tf` — key: `project/production/ap-northeast-2/shared/eks/terraform.tfstate`
  - [x] `providers.tf`, `outputs.tf`, `main.tf` (dev와 동일)
  - [x] `data.tf` — `terraform_remote_state.vpc` key를 production vpc state로 변경
  - [x] `locals.tf`
    - [x] `cluster_name = "eks-practice-production"`, `kubernetes_version = "1.33"`
    - [x] `endpoint_public_access = false` (Private only)
    - [x] 시스템 노드: `t3.medium`(x86, 전체 인스턴스 유형 통틀어 최저가), `min=2/desired=2/max=4` (HA)
    - [x] `node_security_group_tags = { "karpenter.sh/discovery" = "eks-practice-production" }`
    - [x] `upgrade_policy = { support_type = "STANDARD" }`
    - [x] `access_entries`: dev와 동일 (`study` 사용자 + `terraform_execution` Role)
- [x] `terraform fmt` + `terraform validate`
- [x] `terraform plan` 검토

### 3-3. modules/eks-addons 재사용 + environments/production eks-addons 구성 (Karpenter 포함)

- [x] `environments/production/ap-northeast-2/shared/eks-addons/` 신규 root module 생성
  - [x] `backend.tf` — key: `project/production/ap-northeast-2/shared/eks-addons/terraform.tfstate`
  - [x] `providers.tf`, `main.tf`, `outputs.tf` (dev와 동일)
  - [x] `data.tf` — `terraform_remote_state.eks` key를 production eks state로 변경
  - [x] `locals.tf`
    - [x] `replica_counts = {}` (모듈 기본값 사용 — prd는 시스템 노드 2개(HA)이므로 기본 HA replica 적용)
    - [x] `enable_aws_load_balancer_controller = true`, `enable_metrics_server = true`, `enable_karpenter = true`
    - [x] `enable_external_dns = false` (Route53 Hosted Zone 미구성 — 도메인 준비 후 활성화)
    - [x] `karpenter_node_pools`: dev와 동일 4종(general/arm64/gpu/spot), `disruption.consolidateAfter = "300s"`
  - [x] `karpenter.tf` 작성 (dev와 동일 구조: EC2NodeClass + NodePool for_each + finalizer 강제 제거 null_resource)
- [x] `terraform fmt` + `terraform validate`
- [x] `terraform plan` 검토
- [x] Karpenter 노드 IAM Role용 EKS Access Entry 추가 (`modules/eks-addons/1.0.0/main.tf`,
      `aws_eks_access_entry.karpenter_node`, type=`EC2_LINUX`)
  - 원인: eks-blueprints-addons의 karpenter 서브모듈은 노드 IAM Role/Instance Profile만 생성하고
    access entry는 생성하지 않음. EKS managed node group은 access entry가 자동 생성되지만
    Karpenter 노드 Role은 수동 등록이 필요. 미등록 시 kubelet이 `Unauthorized`로 노드 등록 실패.
  - dev에도 동일 모듈을 공유하므로 dev eks-addons apply 시에도 동일 리소스가 추가됨
- [x] EC2NodeClass에 `Name` 태그 추가 (`karpenter.tf`, `spec.tags.Name = "${local.cluster_name}-karpenter"`)
  - 웹 콘솔에서 Karpenter가 생성한 EC2 인스턴스를 시스템 노드그룹과 구분하기 위함
  - production: `eks-practice-production-karpenter`, dev: `eks-practice-develop-karpenter`
  - production apply 후 신규 NodeClaim(`general-7d582`)의 EC2 인스턴스에 태그 적용 확인 완료
- [x] `terraform destroy` 시 Karpenter NodeClaim(EC2 인스턴스) 정리를 보장하는
      `null_resource.karpenter_nodeclaims_drainer` 추가 (`karpenter.tf`)
  - 원인: NodePool에는 `karpenter.sh/termination` finalizer가 있어 Karpenter 컨트롤러가
    연관 NodeClaim(EC2 인스턴스)을 모두 정리해야 destroy가 완료됨. 컨트롤러 응답 불가나
    Spot 종료 지연 시 `kubernetes_manifest.karpenter_node_pool` destroy가 무한 대기할 위험이 있음
  - 해결: NodePool/module.eks_addons보다 먼저 destroy되는 null_resource에서
    `kubectl delete nodeclaims --all --timeout=180s || true` 실행 — 기존
    `karpenter_nodeclass_finalizer_remover`와 동일한 depends_on 패턴 적용
  - production: `terraform validate` + `terraform plan` 검증 완료 (1 to add, 0 to change, 0 to destroy)
  - dev: 동일 코드 적용 (별개의 remote state 이슈로 plan 검증은 보류)

### 3-4. 검증

- [x] `aws eks update-kubeconfig --name eks-practice-production --region ap-northeast-2`
- [x] `kubectl get nodes` - 시스템 노드 2개 확인 (HA)
- [x] `kubectl get pods -A` - 전체 파드 상태 확인
- [x] `kubectl get pods -n kube-system` - 관리형 애드온 확인
- [x] `kubectl get pods -n karpenter` - Karpenter 동작 확인
- [x] `kubectl get ec2nodeclass` / `kubectl get nodepool` — NodeClass/NodePool 등록 확인
- [x] 테스트 Deployment 배포 후 Karpenter 앱 노드 프로비저닝 확인
  - `karpenter-test-inflate` 배포 → NodeClaim `general-rhqch`(m8i-flex.large spot, ap-northeast-2d)
    생성 → access entry 추가 후 노드 `Ready` 전환, 파드 `Running` 확인 → 테스트 Deployment 삭제 완료
    (Karpenter consolidation으로 노드 자동 회수 예정)

---

## Phase 5. GitOps 전환 (Terraform → ArgoCD)

> **목적**: 여러 환경·클러스터로 확장 시 반복 작업을 최소화하기 위해
> Helm 애드온 관리를 Terraform에서 ArgoCD로 이관한다.
>
> **전환 전제**: Phase 2-4 완료 후 진행. ArgoCD가 시스템 노드에 배포된 상태 기준.
>
> **저장소 구성** (Phase 5용 별도 repo 신규 생성):
> - 이 repo(`eks-terraform-practice-with-claude`): Terraform 인프라(IAM Role, SQS, EventBridge 등 AWS 리소스) + ArgoCD 설치만 관리
> - [`eks-practice-devops-manifest`](https://github.com/hul0810/eks-practice-devops-manifest): ArgoCD가 Git 소스로 참조하는 EKS 애드온 ApplicationSet/Helm values 매니페스트
> - [`eks-practice-application-with-claude`](https://github.com/hul0810/eks-practice-application-with-claude): EKS에 배포할 애플리케이션 코드 (Docker 이미지 빌드 소스, 5-3/5-4와 별개로 ArgoCD Application 대상이 될 예정)

### 5-1. ArgoCD 설치

- [x] `modules/eks-addons/main.tf`에 ArgoCD Helm 설치 추가
  - [x] `enable_argocd = true` (aws-ia/eks-blueprints-addons)
  - [x] HA 구성 values 설정 (redis-ha, server/repoServer/applicationSet replicas) —
    `argocd_ha_enabled` 토글 (dev=false, production=true)
  - [x] `CriticalAddonsOnly` toleration 추가 (시스템 노드에 스케줄, redis-ha는 별도 명시)
- [x] dev: `terraform apply` 완료 — argo-cd v9.5.21(app v3.4.3) `helm_release` status=deployed 확인
- [ ] production: `terraform apply` (사용자 직접 실행 필요 — `argocd_ha_enabled=true`)
- [ ] ArgoCD UI 접속 확인 (`kubectl port-forward service/argo-cd-argocd-server -n argocd 8080:443`)

### 5-2. IAM/AWS 리소스와 Helm 리소스 분리

> 이 단계의 핵심: Terraform은 AWS 리소스(IAM Role, SQS, EventBridge)만 관리하고
> Helm Chart 설치는 ArgoCD에 위임한다.

- [ ] `modules/eks-addons/main.tf` 수정
  - [ ] `aws-ia/eks-blueprints-addons` 블록에 `create_kubernetes_resources = false` 추가
    - Terraform이 생성하던 `helm_release` 리소스 제거됨
    - IAM Role, SQS, EventBridge Rule은 계속 Terraform이 관리
- [ ] `terraform plan`으로 `helm_release` 리소스 삭제 확인 후 `terraform apply`

### 5-3. ArgoCD ApplicationSet 작성

> 하나의 ApplicationSet 선언으로 모든 환경에 동일 Chart 배포.
> **저장소**: `eks-practice-devops-manifest` (이 repo가 아님 — ArgoCD가 Git 소스로 참조하는 별도 매니페스트 repo)

- [ ] `eks-practice-devops-manifest` repo에 `applicationsets/` 디렉토리 생성
- [ ] `applicationsets/eks-addons.yaml` 작성
  - [ ] Generator: 환경 목록 (`develop`, `production`)
  - [ ] 공통 Chart 버전 선언 (LBC, kube-prometheus-stack)
  - [ ] 환경별 values 파일 경로 연결 (`values-{{env}}.yaml`)
- [ ] `values/` 디렉토리 생성
  - [ ] `values-develop.yaml` — dev 환경 오버라이드 (replica 수, resource limits 등)
  - [ ] `values-production.yaml` — prd 환경 오버라이드

### 5-4. Karpenter GitOps 전환

- [ ] `modules/karpenter/main.tf`에 `create_kubernetes_resources = false` 추가
  - Terraform: IAM Role + SQS + EventBridge만 유지
  - ArgoCD: Karpenter Helm Chart + EC2NodeClass + NodePool 관리
- [ ] `eks-practice-devops-manifest` repo에 `applicationsets/karpenter.yaml` 작성

### 5-5. 검증

- [ ] ArgoCD UI에서 전체 애드온 Synced 상태 확인
- [ ] `kubectl edit` 으로 임의 변경 후 ArgoCD 자동 복구 확인 (드리프트 감지)
- [ ] 새 환경 추가 시나리오 테스트: ApplicationSet 목록에 환경 1개 추가 → 자동 배포 확인

---

## Phase 6. Observability 구축 (Prometheus + Grafana)

> **전제**: Phase 2-4 완료 후 진행 (Karpenter 앱 노드 프로비저닝 완료 상태)
> kube-prometheus-stack pre-install hook이 앱 노드를 필요로 하므로 Karpenter 이후에 설치한다.

- [ ] `modules/eks-addons/1.0.0/main.tf`에 kube-prometheus-stack 추가
  - [ ] `enable_kube_prometheus_stack = true` (aws-ia/eks-blueprints-addons)
  - [ ] chart 버전 변수화 (`kube_prometheus_stack_chart_version`)
  - [ ] Grafana, Prometheus, Alertmanager values 정의
- [ ] `modules/eks-addons/1.0.0/variables.tf`에 `kube_prometheus_stack_chart_version` 변수 추가
- [ ] `environments/develop/ap-northeast-2/shared/eks-addons/locals.tf`에 버전 추가
- [ ] `terraform apply` 실행
- [ ] `kubectl get pods -n kube-prometheus-stack` — 파드 상태 확인
- [ ] Grafana 대시보드 접속 확인

---

## 기타

- [x] `.gitignore` 작성 (`.terraform/`, `*.tfstate`, `*.tfvars` 등)
- [ ] `README.md` 작성 (구조 설명, 사용 방법)

---

## 2단계: 엔터프라이즈 전환 (멀티 계정, 중앙 집중, 고가용성)

> **목표**: 1단계 기초 구성을 실무 엔터프라이즈 수준으로 개선한다.
> 2계정(Intra/Workload) 격리, Hub-Spoke GitOps·Observability, 보안·정책 거버넌스를 단계적으로 적용한다.
>
> **의존성 순서** (반드시 이 순서로 진행):
> ```
> Phase 7 (Organizations 2계정) → Phase 8 (TGW) → Phase 9 (ArgoCD Hub) → Phase 10 (중앙 Observability)
>                                                ↘ Phase 11 (보안·거버넌스, Phase 7 직후 병렬 가능)
> ```
>
> **비용 경고**: Phase 8(TGW)부터 고정 비용이 크게 증가한다.
> TGW 어태치먼트는 VPC당 ~$36/월, Intra EKS 클러스터는 컨트롤 플레인 $73/월 + 노드 추가.
> **학습 세션 중에만 `terraform apply` 하고 종료 시 `terraform destroy`하는 운영 패턴을 기본으로 한다.**

---

### Phase 7. AWS Organizations + 2계정 구조 (Intra / Workload)

> **목표**: 단일 계정을 Intra(공유 서비스) + Workload(dev/prd) 2계정으로 분리하고,
> SCP 기본 가드레일, IAM Identity Center(SSO), 중앙 로깅의 토대를 마련한다.
>
> **계정 구조**:
> - **Intra 계정** (신규): ArgoCD Hub, 중앙 Observability, TGW 소유자. 공유 서비스 전담.
> - **Workload 계정** (현재 계정 유지): dev + prd EKS 클러스터. 애플리케이션 워크로드 전담.
>
> *(실무 표준은 dev/prd를 별도 계정으로 추가 분리하지만, 비용·복잡도 절감을 위해 2계정으로 단순화)*
>
> **왜 계정을 분리하는가**:
> - **격리(Blast Radius)**: Intra 서비스(ArgoCD, Grafana)와 워크로드 EKS를 계정 경계로 격리.
>   Intra 계정의 장애·오염이 워크로드 계정에 전파되지 않는다.
> - **권한 경계 명확화**: cross-account assume을 명시적으로 허용한 주체만 각 계정에 접근 가능.
> - **비용 가시성**: 공유 서비스 비용 vs 워크로드 비용을 계정별로 즉시 구분.
>
> **비용 영향**: Organizations·SCP·IAM Identity Center 자체는 무료. 추가 비용은 Org Trail S3 등 월 $5~15 수준.
>
> **전제 조건**: 없음. 단, `TerraformExecutionRole`의 trust principal(`account:root`) 재설계 필요.
> Phase 7 착수 전 security-engineer와 IAM 체인 재설계 별도 진행 권장.

- [ ] **멀티 계정 전략 설계** (`docs/multi-account-strategy.md` 신규 작성)
  - [ ] OU 구조: `Infrastructure`(Intra), `Workloads`(dev/prd 공용) 2 OU
  - [ ] State backend 전략: 현재 Workload 계정 S3 버킷 유지 + Intra 계정은 동일 버킷에 cross-account 접근
  - [ ] `TerraformExecutionRole` 재설계: Intra/Workload 계정 각각에 배포 + trust를 Workload 계정 실행 주체로 한정 (`account:root` trust 제거)
- [ ] `global/organizations/` 신규 root module 생성 — Workload(현재) 계정에서 실행
  - [ ] `aws_organizations_account` 2개 발급 (Intra 신규, Workload는 현재 계정 import)
  - [ ] OU 구조 코드화
- [ ] IAM Identity Center(SSO) 활성화 — 계정별 IAM User 난립 대신 중앙 인증 전환
- [ ] SCP 기본 가드레일: 루트 리전 강제(`ap-northeast-2` 외 차단), 루트 사용자 사용 차단, CloudTrail 비활성화 차단
- [ ] Org Trail(중앙 CloudTrail) → Workload 계정 또는 별도 S3 집계
- [ ] `TerraformExecutionRole` Intra 계정에 배포 (bootstrap 절차 문서화)
- [ ] GitHub Actions OIDC → cross-account assume 체인 구성 (IAM User 장기 키 제거)
- [ ] FinOps 자동화: 계정별 AWS Budget + Cost Anomaly Detection 코드화

---

### Phase 8. 네트워크 토폴로지 — Transit Gateway + 중앙 Egress

> **목표**: 예약해둔 TGW 서브넷을 실제로 활용해 Intra/Dev/Prd VPC를 Transit Gateway로 연결하고,
> dev↔prd 직접 통신을 격리한다.
>
> **왜 TGW인가 (VPC Peering 대비)**:
> - **Hub-Spoke 구조 필수**: ArgoCD Hub(intra)가 dev/prd API에 도달하고, 중앙 Grafana가 양쪽 메트릭을 수집하려면
>   transitive 라우팅이 필요하다. Peering은 A↔B, B↔C여도 A↔C 통신 불가 — TGW만 이 요구를 충족.
> - **격리 보장**: TGW route table 분리로 "dev↔prd 직접 통신 차단, 각각 intra하고만 통신" 정책 명시적 강제.
> - **확장성**: VPC 3~4개에선 Peering도 가능하나 10개 이상에서 풀메시 관리가 붕괴한다.
>
> **비용 영향**: TGW 어태치먼트 VPC당 ~$36/월 × VPC 수. 3 VPC 기준 어태치먼트만 ~$108/월.
> 이 로드맵에서 **가장 큰 고정 비용 증가 항목** — 학습 세션에서만 apply/destroy 운영 강력 권장.
>
> **전제 조건**: Phase 7 완료 (멀티 계정 + RAM으로 TGW 공유 필요).

- [ ] CIDR 충돌 사전 검증: dev `10.10.0.0/16`, prd `10.11.0.0/16`, **intra `10.12.0.0/16` 신규 할당**
- [ ] `modules/tgw/1.0.0/` 신규 모듈 생성 (`terraform-aws-modules/transit-gateway` 사용 검토)
  - [ ] TGW route table 2개: `shared`(intra↔all), `isolated`(dev/prd 상호 격리)
- [ ] Intra 계정에 TGW 생성 → RAM으로 Dev/Prd 계정에 공유
- [ ] 각 VPC의 예약된 TGW 서브넷에 `aws_ec2_transit_gateway_vpc_attachment` 생성
  - 현재 VPC 설계에 이미 TGW 서브넷을 예약해둔 이유가 여기서 실현됨
- [ ] `modules/vpc`에 `transit_gateway_routes` 변수 추가 → 모듈 버전 `2.0.0`으로 범프, `moved` 블록으로 state 이전
- [ ] (선택) 중앙 Egress VPC + NAT 통합 → dev/prd의 0.0.0.0/0을 TGW 경유 Egress 계정 NAT로
- [ ] EKS Private 엔드포인트 도달성 검증: intra Hub → dev/prd EKS API (`kubectl` via TGW)
- [ ] Git 태그: `enterprise/hub-spoke-network`

---

### Phase 9. Hub-and-Spoke ArgoCD (중앙 GitOps)

> **목표**: dev/prd에 개별 설치된 ArgoCD를 제거하고, Intra 계정 클러스터에 단일 ArgoCD Hub를 두어
> dev/prd를 spoke로 원격 관리한다.
>
> **왜 중앙 집중인가 (인프라 관리 효율성)**:
> - **운영 표면 1/N 감소**: ArgoCD를 n개 클러스터에 개별 운영 vs Hub 1개 운영. 업그레이드·RBAC·백업이 Hub 한 곳으로 집약.
> - **환경 일관성 보장**: 동일 ApplicationSet이 cluster generator로 dev/prd에 동일 Chart 배포 → 버전 드리프트 구조적 차단.
> - **승격(Promotion) 워크플로**: Hub에서 dev→prd 배포를 한 곳에서 가시화·게이팅.
> - **보안 표면 축소**: spoke에 ArgoCD 없음 → 공격 표면 감소, Hub만 강하게 보호.
>
> **SPOF 검토**: ArgoCD Hub 장애 시 이미 배포된 워크로드는 정상 동작 (ArgoCD는 reconciler이지 데이터 플레인이 아님).
> "신규 배포/드리프트 복구 지연" 리스크만 발생. Hub는 HA 구성으로 보완.
>
> **비용 영향**: Intra EKS 컨트롤 플레인 $73/월 + 소형 노드 ~$30/월 (신규). dev/prd ArgoCD 워크로드 제거로 일부 상쇄.
> Phase 10과 Intra 클러스터를 공유하므로 추가 컨트롤 플레인 비용은 Phase 10에서 분담.
>
> **전제 조건**: Phase 8 완료 (Hub가 TGW 경유로 spoke EKS Private 엔드포인트에 도달 가능해야 함).

- [ ] Intra 계정에 Hub 클러스터 구성 (`environments/intra/ap-northeast-2/shared/eks/`) — 기존 `modules/eks/1.0.0` 재사용
- [ ] Hub ArgoCD 설치 (`argocd_ha_enabled = true`) — `modules/eks-addons/1.0.0` 재사용
- [ ] spoke 클러스터 등록: ArgoCD cluster secret + cross-account IAM
  - [ ] Workload 계정의 dev/prd EKS access entry에 Hub의 ArgoCD IAM Role cross-account 등록
  - [ ] `aws_eks_access_entry` 패턴 확장 (기존 dev/prd의 `access_entries` 블록 참조)
- [ ] Workload 계정 dev/prd `eks-addons`에서 `enable_argocd` 제거 (Phase 5 개별 설치 롤백) + `terraform apply`
- [ ] Hub ArgoCD에 ApplicationSet `cluster generator` 구성 — spoke 라벨로 dev/prd 자동 타겟팅
- [ ] `eks-practice-devops-manifest` repo ApplicationSet을 Hub 기준으로 재작성 (Phase 5-3 계획 통합)
  - 저장소: https://github.com/hul0810/eks-practice-devops-manifest
  - 역할: 애드온 Helm values + MSA 애플리케이션(`eks-practice-application-with-claude`) 배포 매니페스트 관리
- [ ] App-of-Apps 또는 ApplicationSet으로 LBC/Karpenter/kube-prometheus-stack을 spoke에 원격 배포
- [ ] MSA 애플리케이션(`eks-practice-application-with-claude`) ArgoCD Application 등록
  - 저장소: https://github.com/hul0810/eks-practice-application-with-claude
  - dev 클러스터 배포 → 정상 동작 확인
- [ ] Hub 장애 시 spoke 워크로드 정상 동작 검증 (SPOF 아님 확인)
- [ ] GitHub Actions CI/CD 자동화: 이미지 빌드 → ECR push → ArgoCD Image Updater 또는 Argo Rollouts 배포 루프 완성
  - [ ] OIDC 기반 cross-account ECR 접근 (IAM User 장기 키 제거, `eks-practice-application-with-claude` repo GitHub Actions 적용)

---

### Phase 10. 중앙 Observability (Prometheus 원격 쓰기 + 중앙 Grafana)

> **목표**: 각 클러스터의 메트릭·로그를 Intra 계정의 중앙 백엔드로 집계하고,
> 단일 Grafana에서 전 환경을 관측한다.
>
> **왜 중앙화인가**:
> - **단일 관측 창**: dev/prd를 한 Grafana에서 환경 라벨로 필터링. 장애 시 Grafana를 오가지 않는다.
> - **장기 보존 분리**: 클러스터 노드의 Prometheus는 단기 버퍼(2~6h)만, 장기는 중앙 S3 기반에 보존.
>   클러스터가 종료되어도 메트릭이 남아 사후 분석 가능.
> - **비용 효율**: 환경마다 풀 Grafana + 장기 스토리지 대신 중앙 1세트.
>
> **중앙 백엔드 선택 (Thanos vs VictoriaMetrics)**:
> - **VictoriaMetrics 권장** (개인 실습 + 비용 최우선): 단일 바이너리, 메모리/CPU 훨씬 적게 사용, 운영 단순.
> - Thanos: CNCF 표준, 면접 단골이나 컴포넌트 多·무거움. "CNCF 표준 학습" 목표면 선택 가능.
> - 절충안: Phase 10a VictoriaMetrics 먼저 → 여유 시 Phase 10b Thanos 비교 실습.
>
> **비용 영향**: S3 스토리지(소액) + Intra 클러스터 관측 노드(Karpenter Spot으로 절감). Phase 9와 클러스터 공유.
>
> **전제 조건**: Phase 9 완료 (Intra 클러스터 존재) + Phase 8 (spoke→hub remote_write 경로).
> Phase 6의 kube-prometheus-stack을 **로컬 수집기 역할로 재배치** (중앙 전송으로 변경).

- [ ] 각 spoke의 kube-prometheus-stack `remoteWrite` 설정 → Intra 중앙 백엔드 전송 (로컬 장기 보존 비활성)
- [ ] Intra 클러스터에 VictoriaMetrics 배포 (ArgoCD Hub로 배포)
  - [ ] S3 백엔드 설정 (장기 메트릭 보존)
  - [ ] remote_write 인증·암호화: TGW 사설 경로 + TLS
- [ ] Intra 클러스터에 중앙 Grafana 배포
  - [ ] 데이터소스 멀티테넌시: 환경 라벨(`cluster=dev/prd`)로 구분
  - [ ] 핵심 대시보드: 클러스터 오버뷰, Karpenter 노드 현황, 서비스별 SLI
- [ ] Loki 중앙 배포 + 각 클러스터 Alloy(또는 Promtail) → 중앙 Loki
  - [ ] S3 백엔드 설정
- [ ] Alertmanager 중앙화 — 환경별 라우팅 규칙 정의
- [ ] (Phase 10b, 선택) Thanos 비교 실습
- [ ] Git 태그: `enterprise/central-observability`

---

### Phase 11. 보안·정책 거버넌스 (Phase 7 직후 병렬 진행 가능)

> **목표**: 시크릿 외부화, 정책 강제(Policy-as-Code), 런타임·이미지 보안을 전 클러스터에 일관 적용한다.
>
> **왜 필요한가**:
> 멀티 계정·멀티 클러스터 환경에서는 "사람이 일일이 검토"가 불가능하다.
> **정책을 코드로 강제(admission control)** 하지 않으면 환경 간 보안 표준이 드리프트한다.
>
> **가장 시급한 단일 항목**: External Secrets — 현재 ArgoCD admin password 등 시크릿이 state/코드에 노출될 위험.
> security-engineer에게 현재 시크릿 관리 방식 점검 위임 권장.
>
> **비용 영향**: 대부분 오픈소스 (Kyverno, External Secrets 컴퓨트 비용만). Secrets Manager 시크릿당 $0.40/월.
>
> **전제 조건**: Phase 7 (Secrets Manager 계정 경계 확립). Phase 8~10과 병렬 진행 가능.

- [ ] **External Secrets Operator** 배포 (ArgoCD Hub로 전 클러스터 배포)
  - [ ] AWS Secrets Manager/SSM Parameter Store → K8s Secret 동기화
  - [ ] Pod Identity로 인증 (현재 Pod Identity 전략과 일관, IRSA 불필요)
  - [ ] ArgoCD admin password, Helm values 내 시크릿을 Secrets Manager로 이전
- [ ] **Kyverno** admission policy 배포 (YAML 정책, Rego 학습 곡선 없음)
  - [ ] 리소스 limit 필수 강제
  - [ ] `latest` 이미지 태그 금지
  - [ ] ECR(특정 레지스트리)만 허용
  - [ ] `hostPath` 마운트 금지
  - [ ] Pod Security Standards(`restricted`) 네임스페이스 적용
- [ ] Org SCP/Tag Policy로 태그 거버넌스를 계정 레벨까지 확장
  - 현재 `docs/tag-governance.md`의 Terraform 태그 강제를 AWS 정책으로 보완
- [ ] ECR Enhanced Scanning (Amazon Inspector) 활성화 — CVE 자동 스캔 (기존 basic scan 업그레이드)
- [ ] EKS Audit Log 활성화 (prd만) → CloudWatch 집계
- [ ] (선택) Falco 런타임 위협 탐지 배포
- [ ] Git 태그: `enterprise/hub-spoke-eks` (2단계 완료)
