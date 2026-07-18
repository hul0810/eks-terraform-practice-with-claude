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
| `foundation/single-account-eks` | 1단계(Phase 1~5) 완료 시 | 단일 계정, dev/prd 2클러스터, GitOps·Observability 포함 기초 구성 |
| `enterprise/hub-spoke-eks` | 2단계(Phase 6~9) 완료 시 | 2계정(monitoring/workload), VPC Peering(수동 관리), Hub-Spoke ArgoCD·Observability, 보안 거버넌스 |

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
  - [x] TGW 서브넷 (Transit Gateway 어태치먼트용, intra 타입 활용) — 확장성을 위해 예약만 해두고 실제 TGW 연결(옛 Phase 8)은 비용 문제로 보류. 서브넷 구성 자체는 유지
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
  - [x] **EKS 관리형 추가 (`aws_eks_addon`)**
    - [x] `aws-secrets-store-csi-driver-provider` v3.1.1-eksbuild.1 — Secrets Store CSI Driver + ASCP 번들
      - IAM 불필요 (ASCP 자체 IAM 없음 — 앱 Pod ServiceAccount에 IAM 부여)
      - dev 시스템 노드 pod 한계(17) 해소: CoreDNS 2→1, EBS CSI Controller 2→1 replica (비용 예외)
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
    - [x] `enable_nat_gateway = true`, `single_nat_gateway = true` (비용 예외 — CLAUDE.md 참조. HA 복원: `single_nat_gateway = false`)
    - [x] `cluster_name = "eks-practice"` (Karpenter 탐색 태그)
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
    - [x] `enable_external_dns = true`, `external_dns_route53_zone_arns` 설정 (pyhtest.com zone ARN — data source 참조)
    - [x] `enable_argo_rollouts = true` (Canary·Blue-Green 배포 전략 지원)
    - [x] ArgoCD Ingress 설정 — hostname: `argocd.pyhtest.com`, ALB + ACM + ExternalDNS + admin bcrypt 패스워드
    - [x] `karpenter_node_pools`: dev와 동일 4종(general/arm64/gpu/spot), `disruption.consolidateAfter = "300s"`
    - [x] `enable_secrets_store_csi_driver = true`, `secrets_store_csi_driver_addon_version = "v3.1.1-eksbuild.1"` — Secrets Store CSI Driver + ASCP 번들 (코드 완료, `terraform apply` 필요)
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

### 3-4. modules/ecr 재사용 + environments/production ecr 추가

> dev Phase 2-5와 동일 패턴. production은 `name_suffix=""` (서비스명 suffix 없음), `lifecycle_tagged_count = 30`

- [x] `environments/production/ap-northeast-2/api-gateway/ecr/` 신규 root module 생성 (`eks-practice-api-gateway`)
- [x] `environments/production/ap-northeast-2/catalog/ecr/` 신규 root module 생성 (`eks-practice-catalog`)
- [x] `environments/production/ap-northeast-2/order/ecr/` 신규 root module 생성 (`eks-practice-order`)

### 3-5. 검증

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

## Phase 4. ArgoCD 설치 (dev/prd)

> **목적**: dev/prd 클러스터에 ArgoCD를 설치하고 외부 접근 가능한 상태로 구성한다.
> Helm 애드온 GitOps 전환(blueprints → ArgoCD 위임)과 Hub-Spoke 중앙 GitOps는 Phase 6(2단계)에서 진행한다.
>
> **전제**: Phase 2-4 완료 후 진행 (Karpenter 시스템 노드 Ready 상태 기준).

- [x] `modules/eks-addons/main.tf`에 ArgoCD Helm 설치 추가
  - [x] `enable_argocd = true` (aws-ia/eks-blueprints-addons)
  - [x] HA 구성 values 설정 (redis-ha, server/repoServer/applicationSet replicas) —
    `argocd_ha_enabled` 토글 (dev=false, production=true)
  - [x] `CriticalAddonsOnly` toleration 추가 (시스템 노드에 스케줄, redis-ha는 별도 명시)
- [x] ArgoCD admin 패스워드 bcrypt 해시 주입 (`argocd_admin_password_bcrypt` — Terraform `bcrypt()` 미사용, apply마다 재시작 방지)
- [x] ArgoCD Ingress 설정 추가
  - [x] dev: `argocd-develop.pyhtest.com` (수정 전: `argo-develop.pyhtest.com` → ExternalDNS로 자동 전환)
  - [x] production: `argocd.pyhtest.com` (ALB + ACM + ExternalDNS 자동 Route53 레코드 생성)
- [x] dev: argo-cd v9.5.21(app v3.4.3) helm_release status=deployed 확인
- [ ] ArgoCD UI 접속 확인 (dev: `https://argocd-develop.pyhtest.com` / prd: `https://argocd.pyhtest.com`)

---

## Phase 5. Observability 인프라 구성 (monitoring EKS 클러스터 + OTel Spoke)

> **목표**: Observability 전용 EKS 클러스터(monitoring, 10.12.0.0/16)의 인프라를 구성하고,
> dev/prd 클러스터에 OTel Spoke Collector를 준비한다.
>
> **결정 사항**: LGTM 스택(Mimir·Loki·Tempo·Grafana)과 OTel Operator·Gateway는 **GitOps로 직행**.
> Phase 5에서는 Terraform으로 클러스터 인프라(VPC·EKS·EKS Addons)만 구성하고,
> LGTM 배포는 Phase 6(Hub-Spoke ArgoCD) 완료 후 `devops-manifest` 저장소에서 ArgoCD Application으로 관리한다.
>
> **아키텍처**: dev/prd OTel DaemonSet(spoke) → monitoring OTel Gateway(hub, GitOps 배포) → LGTM 백엔드
> **전제**: Phase 2-4 완료. cert-manager Bootstrap 애드온 설치 완료 (OTel Operator 전제 조건).

### 5-1. modules/vpc/1.0.0 — VPC Peering + TGW 옵션 추가 ❌ 취소 (수동 관리로 전환)

> **취소 사유**: monitoring↔dev/prd는 계정이 다른 크로스 계정 피어링(계정 ID는
> `docs/network-design.md` 참조)이라 모듈에 변수로 넣으면 root module마다 상대
> 계정 provider 배선이 필요해진다. 연결 수가 2개뿐이고 변경 빈도도 낮아
> IaC 비용을 들이지 않고 **AWS CLI로 수동 관리**하기로 결정했다 (원래는 Phase 8
> TGW 도입 시 대체될 임시 구성으로 시작했으나, TGW 자체를 비용 문제로 취소하면서
> VPC Peering이 영구 구성이 되었다 — 하단 "2단계" 섹션 참조). 아래 항목은 실제
> 코드로 구현된 적이 없다 (계획만 있었고 착수 전 취소됨). 절차는
> `docs/network-design.md` 참조.

- [ ] ~~`modules/vpc/1.0.0/variables.tf` — `vpc_peering_create`, `vpc_peering_routes`, `transit_gateway_id`, `transit_gateway_routes` 추가~~ (취소)
- [ ] ~~`modules/vpc/1.0.0/main.tf` — 피어링·TGW 리소스 추가~~ (취소)
- [ ] ~~`modules/vpc/1.0.0/outputs.tf` — `vpc_peering_connection_ids`, `tgw_attachment_id` 추가~~ (취소)

### 5-2. modules/eks-addons/1.0.0 — OTel Spoke Collector 추가 ✅

- [x] `modules/eks-addons/1.0.0/variables.tf` — `enable_otel_spoke_collector`, `otel_gateway_endpoint`, `otel_spoke_operator_chart_version`
- [x] `modules/eks-addons/1.0.0/main.tf` — OTel Operator helm_release + DaemonSet(`otel-spoke-node`) + Deployment(`otel-spoke-singleton`) CRD
  - k8s_cluster receiver는 DaemonSet에서 분리해 Deployment로 관리 (중복 메트릭 방지)
- [x] `modules/eks-addons/1.0.0/CLAUDE.md` — OTel spoke 섹션 + GitOps 전환 계획 추가

### 5-3. monitoring/ 환경 구성 (클러스터 인프라만) ✅

> `monitoring/environments/ap-northeast-2/shared/` 디렉토리
> 모듈 source 경로: `../../../../../modules/{name}/1.0.0` (루트까지 5단계)
> **LGTM 스택은 이 단계에서 구성하지 않는다 — Phase 6 GitOps에서 배포**

> **참고 (2026-07-17 결정)**: 당초 계획은 공유 서비스(ArgoCD Hub·중앙 Observability 등)를
> 별도의 Intra 계정에 두는 것이었으나, 계정을 추가로 늘리지 않고 이미 존재하는 `monitoring`
> 계정(`terraform-monitoring` profile, 계정 ID는 `docs/network-design.md` 참조)이 그 역할을
> 전부 흡수하기로 했다. 즉 이 프로젝트는 **workload 계정 + monitoring 계정, 2계정 구조가
> 이미 완성된 상태**다. Phase 7은 "신규 계정 생성"이 아니라 이 2계정에 AWS Organizations
> 거버넌스 계층(OU·SCP·IAM Identity Center)을 얹는 작업으로 범위가 바뀐다 — 아래 Phase 6~9의
> "Intra 계정" 서술은 전부 "monitoring 계정"으로 대체한다.

- [x] `global/tag-policy/main.tf` — "monitoring" 환경 허용값 추가
- [x] `monitoring/environments/ap-northeast-2/shared/vpc/` 구성
  - [x] CIDR: 10.12.0.0/16 (Intra 계정 신규 생성 계획 취소 — monitoring 계정이 공유 서비스
    역할을 영구적으로 흡수하므로 이 VPC는 이전 없이 그대로 유지된다)
  - [ ] ~~`vpc_peering_create`: dev/prd VPC Peering 요청자 생성~~ (취소 — 5-1 참조, AWS CLI 수동 관리로 전환)
- [x] `monitoring/environments/ap-northeast-2/shared/eks/` 구성
  - [x] `cluster_name = "eks-practice-mon"`, `kubernetes_version = "1.34"`, cert-manager Bootstrap 포함
- [x] `monitoring/environments/ap-northeast-2/shared/eks-addons/` 구성
  - [x] LBC, ExternalDNS, Karpenter, Metrics Server 활성화 (ArgoCD·OTel spoke 미포함)

### 5-4. VPC Peering(AWS CLI 수동) + dev/prd OTel spoke 활성화

> 절차·명령어는 `docs/network-design.md` 참조. VPC peering은 Terraform 코드가
> 아니라 AWS CLI로 직접 생성하므로 아래 항목은 `.tf` 변경이 아니다.

- [x] `project/environments/develop/.../eks-addons/locals.tf` — `enable_otel_spoke_collector=false` 플레이스홀더 (NLB DNS 입력 대기)
- [x] `project/environments/production/.../eks-addons/locals.tf` — 동일
- [x] `docs/network-design.md` 절차대로 mon-to-dev, mon-to-prd VPC Peering 생성 + 라우트 추가 (AWS CLI, 2026-07-01)
- [x] `aws ec2 describe-vpc-peering-connections`로 `active` 상태 확인 → 문서의 "연결 목록" 표에 PCX ID 기록
      (`pcx-07fa1a0e9eb100e47`, `pcx-084a197c6a2532991`)
- [ ] monitoring eks, eks-addons apply (2단계)
- [ ] GitOps로 OTel Operator·Gateway·LGTM 배포 (Phase 6 이후)
- [ ] OTel Gateway NLB 호스트명 확인 후 dev/prd eks-addons `enable_otel_spoke_collector=true` + endpoint 입력 → apply

### 5-5. 검증

- [ ] `aws eks update-kubeconfig --name eks-practice-mon --region ap-northeast-2`
- [ ] `kubectl get nodes` — monitoring 클러스터 시스템 노드 확인
- [ ] `kubectl get pods -A` — LBC·ExternalDNS·Karpenter·Metrics Server 확인
- [ ] `aws ec2 describe-vpc-peering-connections --filters Name=status-code,Values=active` — Peering 상태 확인
- [ ] (Phase 6 이후) `kubectl get opentelemetrycollector -A` — spoke 인스턴스 확인
- [ ] (Phase 6 이후) Grafana UI 접속 (`https://grafana.pyhtest.com`)

---

## 2단계: 엔터프라이즈 전환 (멀티 계정, 중앙 집중, 고가용성)

> **목표**: 1단계 기초 구성을 실무 엔터프라이즈 수준으로 개선한다.
> 2계정(monitoring/workload) 격리, Hub-Spoke GitOps·Observability, 보안·정책 거버넌스를 단계적으로 적용한다.
>
> **의존성 순서** (반드시 이 순서로 진행):
> ```
> Phase 6 (ArgoCD Hub GitOps) → Phase 7 (Organizations 거버넌스) → Phase 8 (중앙 Observability)
>                                                                ↘ Phase 9 (보안·거버넌스, Phase 7 직후 병렬 가능)
> ```
>
> **네트워크 토폴로지 결정**: 계정 간 연결에 Transit Gateway를 도입하지 않는다.
> TGW 어태치먼트 비용(VPC당 ~$36/월, 3 VPC 기준 ~$108/월)이 이 로드맵에서 가장 큰
> 고정비 증가 항목이라 비용 문제로 취소했다. monitoring↔Workload 연결은 Phase 5에서
> 이미 구축한 VPC Peering(AWS CLI 수동 관리)을 계속 사용한다 — 절차·이유는
> `docs/network-design.md` 참조.
>
> **비용 경고**: Phase 8(중앙 Observability)의 워크로드(VictoriaMetrics·Grafana·Loki)는
> monitoring 계정의 기존 EKS 클러스터(`eks-practice-mon`)에 얹히므로 컨트롤 플레인 비용이
> 신규로 추가되지 않는다 — 클러스터 자체가 이미 상시 운영 중이기 때문이다. 노드 비용만
> 워크로드 증가에 비례해 늘어난다(Karpenter Spot으로 절감).
> **학습 세션 중에만 `terraform apply` 하고 종료 시 `terraform destroy`하는 운영 패턴을 기본으로 한다.**

---

### Phase 6. Hub-and-Spoke ArgoCD + GitOps Bridge (중앙 GitOps)

> **목표**: dev/prd에 개별 설치된 ArgoCD를 제거하고, **monitoring 계정의 기존 EKS 클러스터
> (`eks-practice-mon`)에 이미 설치된 ArgoCD**를 Hub로 삼아 spoke(dev/prd)를 원격 관리한다.
> 별도 Hub 전용 클러스터를 새로 만들지 않는다 — monitoring이 이미 그 역할이다(위 "참고" 박스 참조).
>
> **GitOps Bridge 패턴 채택** (공식 참조: [gitops-bridge-dev/gitops-bridge](https://github.com/gitops-bridge-dev/gitops-bridge),
> [terraform-helm-gitops-bridge](https://github.com/gitops-bridge-dev/terraform-helm-gitops-bridge)):
> 애드온(LBC, Karpenter, ExternalDNS 등)은 클러스터 밖 AWS 리소스(IAM Role 등)에 의존하는데,
> 그 IAM Role ARN 같은 메타데이터는 Terraform이 만든 결과물이지만 Helm chart 설치 자체는
> GitOps(ArgoCD)가 한다. 이 둘을 잇는 다리가 **ArgoCD `cluster` Secret**이다 — Terraform이
> IAM Role만 만든 뒤 그 ARN을 이 Secret의 annotation에 적어두면, ArgoCD ApplicationSet의
> `cluster generator`가 그 Secret을 읽어 각 애드온 Helm values(예:
> `serviceAccount.annotations.eks\.amazonaws\.com/role-arn`)에 자동 주입한다.
>
> **ArgoCD 자신은 예외적으로 계속 Terraform 관리**: GitOps Bridge/Hub-Spoke 패턴 자체가
> ArgoCD를 전제로 동작하므로, ArgoCD 설치 자체를 ArgoCD로 관리할 수는 없다(부트스트랩 역설).
> monitoring 기준 실제 구현은 `modules/eks-addons/2.0.0`의 전용 인스턴스
> `eks_blueprints_addons_argocd`다(6-2/6-3 참고) — develop/production은 아직 `1.0.0`의
> `enable_argocd` 경로 그대로다.
>
> **점진적 진행 원칙**: 아래 체크리스트는 **한 번에 몰아서 하지 않고, 항목 하나씩 순서대로
> 진행하며 각 단계에서 실제로 GitOps Bridge가 어떻게 동작하는지 확인**한다. 특히 IAM
> 메타데이터 주입(3번)은 애드온마다 조건이 다를 수 있어(Pod Identity vs IRSA, blueprints
> `enable_*`가 IAM/Helm을 함께 묶어서 만드는지 등) 애드온 1개를 먼저 끝까지 검증한 뒤에만
> 다음 애드온으로 넘어간다.
>
> **왜 중앙 집중인가**:
> - **운영 표면 1/N 감소**: ArgoCD를 n개 클러스터에 개별 운영 vs Hub 1개 운영. 업그레이드·RBAC·백업이 Hub 한 곳으로 집약.
> - **환경 일관성 보장**: 동일 ApplicationSet이 cluster generator로 dev/prd에 동일 Chart 배포 → 버전 드리프트 구조적 차단.
> - **승격(Promotion) 워크플로**: Hub에서 dev→prd 배포를 한 곳에서 가시화·게이팅.
> - **보안 표면 축소**: spoke에 ArgoCD 없음 → 공격 표면 감소, Hub만 강하게 보호.
>
> **SPOF 검토**: ArgoCD Hub 장애 시 이미 배포된 워크로드는 정상 동작 (ArgoCD는 reconciler이지 데이터 플레인이 아님).
>
> **비용 영향**: 신규 클러스터가 없으므로 컨트롤 플레인 추가 비용 없음(monitoring 클러스터는
> 이미 상시 운영 중). dev/prd 개별 ArgoCD 워크로드 제거로 그쪽 노드 여유가 오히려 늘어난다.
>
> **전제 조건**: Phase 4-1 완료(ArgoCD 설치됨), Phase 5-3 완료(monitoring 클러스터 존재).

**6-1. GitOps Bridge 개념 실습 (monitoring 자기 자신 대상, 위험 낮음) — 완료 (2026-07-17)**
- [x] ArgoCD `cluster` Secret 구조 이해
- [x] monitoring 클러스터 자기 자신을 가리키는 `cluster` Secret을 Terraform으로 생성,
      ArgoCD가 인식하는지 확인
- [x] `argocd-application-controller`에 IRSA + EKS Access Entry + 읽기 전용 ClusterRole 구성
      (`gitops-bridge-irsa.tf`)
- [x] 테스트 Application(devops-manifest 저장소, `gitops-bridge-test`)으로 실제 배포 검증 —
      읽기 성공, 쓰기 차단 확인(least-privilege 정상 동작). 이 Application은 6-2 이후에도
      계속 재사용한다.

**6-2. 애드온 1개 파일럿 전환 — 상태 없고 IAM 불필요한 것부터 (metrics-server) — 완료 (2026-07-17)**
- [x] metrics-server를 Terraform Helm 관리에서 ArgoCD Application(devops-manifest
      `charts/eks-addons/metrics-server`)으로 무중단 이관 (destination: `in-cluster`)
- [x] `modules/eks-addons/2.0.0`을 신설해 ArgoCD 전용(`eks_blueprints_addons_argocd`)과 나머지
      (`eks_blueprints_addons`) 모듈 인스턴스로 분리 — GitOps Bridge 최종 전환
      (`create_kubernetes_resources`) 구조 확보. `1.0.0`은 원본 그대로 유지해 develop/production에
      영향 없음(monitoring만 `2.0.0` 참조로 전환)

**6-3. IAM이 필요한 애드온 전환 — 진짜 브릿지 실습 (aws-load-balancer-controller) — 완료 (2026-07-17)**
- [x] LBC의 IAM Role/Policy는 Terraform 유지, Helm release만 ArgoCD Application(devops-manifest
      `charts/eks-addons/aws-load-balancer-controller`)으로 무중단 이관 (destination: `in-cluster`)
- [x] `modules/eks-addons/2.0.0`에 `create_kubernetes_resources=false` 고정된
      `eks_blueprints_addons_gitops` 인스턴스 신설 — IAM은 유지·Helm만 이관된 addon 전용,
      6-4 이후 addon들도 재사용
- [x] Helm chart의 webhook 인증서 비결정성 문제 대응 패턴 확립 — `ignoreDifferences` +
      `syncPolicy.syncOptions: [RespectIgnoreDifferences=true]` + 배열 전체 커버용
      `jqPathExpressions` (`temp/gitops-migration-lbc.md`, `temp/gitops-bridge-terraform-notes.md`)

**6-4. 나머지 monitoring 애드온 순차 전환**
- [x] argo-rollouts — IAM 불필요, 6-2 패턴으로 완전 이관 (2026-07-17). CRD 5개(150~200KB)가
      `kubectl apply`의 256KB annotation 제한에 걸릴 수 있어 `ServerSideApply=true` 필요함을
      확인. CRD의 `preserveUnknownFields` 필드는 API 서버가 저장을 거부하는 v1 CRD 고유 특성이라
      `ignoreDifferences` 필요 (`temp/gitops-migration-argo-rollouts.md`)
- [x] karpenter — 6-3 패턴, 컨트롤러 IRSA·노드 IAM Role/Instance Profile·SQS 인터럽션 큐·
      EventBridge Rule까지 전부 `eks_blueprints_addons_gitops`로 이전 (2026-07-18)
- [x] external-dns — 6-3 패턴, cross-account assume-role 유지 (2026-07-18)
- [x] external-secrets — 6-3 패턴, CRD 24개 중 2개(658KB) `ServerSideApply=true`로 대응
      (2026-07-18)
- [x] **부수 발견 — ArgoCD 자신의 부트스트랩 순환 의존성 해소**: `argocd-github-app-repo-creds`가
      ESO(`ExternalSecret`)를 거쳐 생성되던 구조였는데, "완전 재구축" 시나리오를 가정해보니
      ArgoCD 부트스트랩 → ESO 필요 → ESO도 GitOps 관리 대상이면 ArgoCD가 먼저 떠야 함 →
      순환되는 문제를 발견했다. Terraform이 SSM을 `data "aws_ssm_parameter"`로 직접 읽어
      `kubernetes_secret_v1`로 만드는 방식으로 전환해 ESO 의존을 제거했다
      (`docs/addon-strategy.md` "GitOps 관리 경계" 원칙 그대로 적용). Image Updater의
      git-creds는 이 순환에 해당하지 않아 ESO 경유 그대로 둔다.
- [x] **부수 발견 — ArgoCD UI rollout-extension 회귀**: `enable_argo_rollouts=false`(6-4에서
      Terraform이 손을 뗀 것)가 ArgoCD Helm values의 rollout-extension 표시 여부에도
      재사용되고 있어, 이관 후 조용히 꺼질 뻔했다. `argo_rollouts_extension_enabled` 변수를
      신설해 "Terraform 설치 여부"와 "클러스터에 실제로 있는지"를 분리했다.
- [x] **부수 발견 — Karpenter `clusterEndpoint` 하드코딩으로 인한 신규 노드 조인 불가**:
      monitoring teardown/재구축 후 Karpenter가 새 EC2 노드를 계속 만들었지만 전부
      `kubectl get nodes`에 나타나지 않는 채로 멈췄다(nodeclaim `Registered: Unknown` 무한
      대기). 근본 원인은 `charts/eks-addons/karpenter/values-override.yaml`의
      `settings.clusterEndpoint`가 이전 클러스터의 EKS API 엔드포인트 해시를 그대로 가리키고
      있어, Karpenter가 신규 노드의 nodeadm 부트스트랩 설정에 존재하지 않는 호스트명을 주입해
      kubelet이 DNS 조회부터 실패(`no such host`)한 것이었다(SSM Session Manager로
      `journalctl -u kubelet` 직접 확인, IAM/SG/라우팅/NACL은 전부 정상이었음). `clusterEndpoint`를
      비우고 `settings.eksControlPlane=true`로 전환해 Karpenter가 시작 시 `eks:DescribeCluster`
      API로 스스로 엔드포인트를 조회하도록 근본 수정했다 — 필요한 IAM 권한은 blueprints 모듈
      기본 정책에 이미 포함되어 있어 추가 변경 불필요. teardown/재구축이 잦은 실습 환경
      특성상 이 클래스의 값(클러스터 고유 ID가 박히는 값)은 전부 정적 오버라이드보다 런타임
      자동 탐지를 우선 검토해야 한다는 일반 원칙을 확인했다.
- [x] argocd-image-updater — `helm_release`를 devops-manifest
      `charts/eks-addons/argocd-image-updater`로 이관 완료(2026-07-18). ECR ext: 스크립트
      인증(Alpine initContainer로 docker-credential-ecr-login 주입)까지 전부 무중단 인수.
      IAM(ECR 인증/read 정책)은 계속 Terraform 유지
      - [x] `kubernetes_manifest.argocd_image_updater_git_creds`(ExternalSecret)도 함께 이관 완료
- [x] **ClusterSecretStore/ExternalSecret GitOps 이관 완료** (2026-07-18) — notification
      secrets 4개(argo-rollouts/argocd SecretStore+ExternalSecret)와 범용
      `aws_parameterstore_secret_store`(ClusterSecretStore) 전부 devops-manifest Application으로
      이관, sync 검증(파드 재시작 0회) 후 Terraform state 정리 완료. IAM Role/ServiceAccount는
      계속 Terraform 유지
- [x] **Karpenter NodeClass/NodePool GitOps 이관 완료** (2026-07-18) — devops-manifest
      `charts/eks-addons/karpenter-resources`(plain-manifest Application, 이 저장소 최초의
      non-Helm 소스)로 이관. `limits.cpu` 등 순수 숫자 Quantity 필드는 YAML에서 quote 없이
      써야 한다는 함정 발견(`temp/gitops-migration-karpenter-nodeclass-nodepool.md`).
      (`argocd_cluster_self`(`gitops-bridge-irsa.tf`)는 검토 결과 후보 아님 — ArgoCD 자신의
      클러스터 등록 정보라 repo-creds와 같은 영구 Terraform 예외로 남는다.)

**6-4 완료 — GitOps Bridge로 이관된 monitoring 애드온**: aws-load-balancer-controller,
metrics-server, argo-rollouts, karpenter(+NodeClass/NodePool), external-dns,
external-secrets, argocd-image-updater(+git-creds), notification secrets(argo-rollouts/
argocd), 범용 ClusterSecretStore. **영구 Terraform 예외**: ArgoCD 자신(Helm release),
ArgoCD repo-creds, ArgoCD 자신의 cluster Secret(`argocd_cluster_self`).

**6-5. Hub-Spoke 확장 — dev/prd를 spoke로 등록**
- [ ] dev/prd EKS access entry에 Hub(monitoring) ArgoCD의 IAM Role 등록
      (`aws_eks_access_entry` 패턴 확장 — 기존 dev/prd `access_entries` 블록 참조)
- [ ] dev/prd 각각을 가리키는 `cluster` Secret을 monitoring의 ArgoCD 네임스페이스에 생성
- [ ] dev/prd `eks-addons`에서 `enable_argocd` 제거 (Phase 4-1 개별 설치 롤백)
- [ ] Hub ArgoCD에 ApplicationSet `cluster generator` 구성 — spoke 라벨로 dev/prd 자동 타겟팅

**6-6. GitOps 저장소 구조화 및 애플리케이션 배포**
- [ ] `eks-practice-devops-manifest` repo에 ApplicationSet 작성
  - 저장소: https://github.com/hul0810/eks-practice-devops-manifest
  - 역할: 애드온 Helm values + MSA 애플리케이션 배포 매니페스트 관리
- [ ] App-of-Apps 또는 ApplicationSet으로 dev/prd 애드온 전체를 6-1~6-4 패턴대로 원격 배포
- [ ] MSA 애플리케이션(`eks-practice-application-with-claude`) ArgoCD Application 등록
  - 저장소: https://github.com/hul0810/eks-practice-application-with-claude
  - dev 클러스터 배포 → 정상 동작 확인
- [ ] Hub 장애 시 spoke 워크로드 정상 동작 검증 (SPOF 아님 확인)
- [ ] GitHub Actions CI/CD 자동화: 이미지 빌드 → ECR push → ArgoCD Image Updater 또는 Argo Rollouts 배포 루프 완성
  - [ ] OIDC 기반 ECR 접근 (IAM User 장기 키 제거, `eks-practice-application-with-claude` repo GitHub Actions 적용)

---

### Phase 7. AWS Organizations 거버넌스 (monitoring / workload 기존 2계정 대상)

> **목표**: 이미 물리적으로 분리되어 있는 monitoring(공유 서비스) / workload(dev/prd) 2계정을
> AWS Organizations 아래로 묶고, SCP 기본 가드레일·IAM Identity Center(SSO)·중앙 로깅의
> 토대를 마련한다. **신규 계정을 만드는 단계가 아니다** — 당초 계획했던 별도 Intra 계정 신설은
> 취소됐고(위 "참고" 박스 참조), monitoring 계정이 그 역할을 이미 수행 중이므로 이 Phase는
> "이미 있는 2계정에 거버넌스 계층을 얹는" 작업으로 범위가 좁아졌다.
>
> **계정 구조 (이미 완성됨)**:
> - **monitoring 계정** (기존): ArgoCD Hub, LGTM 스택 등 공유 서비스 전담.
> - **workload 계정** (기존): dev + prd EKS 클러스터. 애플리케이션 워크로드 전담.
>
> *(실무 표준은 dev/prd를 별도 계정으로 추가 분리하지만, 비용·복잡도 절감을 위해 2계정으로 단순화)*
>
> **왜 거버넌스가 필요한가** (계정 분리는 이미 됐으니 아래는 그 위에 얹는 이유):
> - **권한 경계 명확화**: cross-account assume을 명시적으로 허용한 주체만 각 계정에 접근 가능하도록 SCP로 강제.
> - **비용 가시성**: 공유 서비스 비용 vs 워크로드 비용을 계정별로 이미 구분 가능(청구서 분리) — Organizations는 여기에 예산 집계·이상 감지를 더한다.
> - **중앙 인증**: 계정별 IAM User 난립 대신 IAM Identity Center(SSO) 단일 로그인.
>
> **비용 영향**: Organizations·SCP·IAM Identity Center 자체는 무료. 추가 비용은 Org Trail S3 등 월 $5~15 수준.
>
> **전제 조건**: Phase 6 완료 권장 (Hub-Spoke 패턴 검증 후 거버넌스 적용).
> `TerraformExecutionRole`의 trust principal(`account:root`) 재설계 필요 — security-engineer 사전 검토 권장.

- [ ] **거버넌스 전략 설계** (`docs/multi-account-strategy.md` 신규 작성)
  - [ ] OU 구조: `Infrastructure`(monitoring), `Workloads`(dev/prd 공용) 2 OU
  - [ ] State backend 전략: 현재 workload 계정 S3 버킷 유지 + monitoring 계정은 동일 버킷에 cross-account 접근
  - [ ] `TerraformExecutionRole` 재설계: monitoring/workload 계정 각각에 배포 + trust를 실행 주체로 한정 (`account:root` trust 제거)
- [ ] `global/organizations/` 신규 root module 생성 — workload 계정에서 실행
  - [ ] 기존 monitoring/workload 2개 계정을 `aws_organizations_account` 리소스로 **import**(신규 발급 아님 — 이미 존재하는 계정을 Organizations 관리 범위로 편입)
  - [ ] OU 구조 코드화
- [ ] IAM Identity Center(SSO) 활성화 — 계정별 IAM User 난립 대신 중앙 인증 전환
- [ ] SCP 기본 가드레일: 루트 리전 강제(`ap-northeast-2` 외 차단), 루트 사용자 사용 차단, CloudTrail 비활성화 차단
- [ ] Org Trail(중앙 CloudTrail) → workload 계정 또는 별도 S3 집계
- [ ] `TerraformExecutionRole` monitoring 계정에 맞게 재배포(신뢰 정책 재설계 반영, bootstrap 절차 문서화)
- [ ] GitHub Actions OIDC → cross-account assume 체인 구성 (IAM User 장기 키 제거)
- [ ] FinOps 자동화: 계정별 AWS Budget + Cost Anomaly Detection 코드화

---

### Phase 8. 중앙 Observability (Prometheus 원격 쓰기 + 중앙 Grafana)

> **목표**: 각 클러스터의 메트릭·로그를 monitoring 계정의 중앙 백엔드로 집계하고,
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
> - 절충안: Phase 9a VictoriaMetrics 먼저 → 여유 시 Phase 9b Thanos 비교 실습.
>
> **비용 영향**: S3 스토리지(소액) + monitoring 클러스터 관측 노드 증설분(Karpenter Spot으로
> 절감) — 컨트롤 플레인은 신규 비용 없음(기존 클러스터 재사용, Phase 6 참조).
>
> **전제 조건**: Phase 7 완료 권장(거버넌스 정착 후 진행). monitoring 계정/클러스터 자체는
> 이미 Phase 5에서 구축 완료 — 별도 이전 작업 불필요.
> spoke→hub remote_write 경로는 Phase 5에서 구축한 VPC Peering(수동 관리,
> `docs/network-design.md`)을 그대로 사용한다 — 별도 네트워크 구축 불필요.
> Phase 5의 kube-prometheus-stack을 **로컬 수집기 역할로 재배치** (중앙 전송으로 변경).

- [ ] 각 spoke의 kube-prometheus-stack `remoteWrite` 설정 → monitoring 중앙 백엔드 전송 (로컬 장기 보존 비활성)
- [ ] monitoring 클러스터에 VictoriaMetrics 배포 (ArgoCD Hub로 배포)
  - [ ] S3 백엔드 설정 (장기 메트릭 보존)
  - [ ] remote_write 인증·암호화: VPC Peering 사설 경로 + TLS
- [ ] monitoring 클러스터에 중앙 Grafana 배포
  - [ ] 데이터소스 멀티테넌시: 환경 라벨(`cluster=dev/prd`)로 구분
  - [ ] 핵심 대시보드: 클러스터 오버뷰, Karpenter 노드 현황, 서비스별 SLI
- [ ] Loki 중앙 배포 + 각 클러스터 Alloy(또는 Promtail) → 중앙 Loki
  - [ ] S3 백엔드 설정
- [ ] Alertmanager 중앙화 — 환경별 라우팅 규칙 정의
- [ ] (Phase 9b, 선택) Thanos 비교 실습
- [ ] Git 태그: `enterprise/central-observability`

---

### Phase 9. 보안·정책 거버넌스 (Phase 7 직후 병렬 진행 가능)

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
> **전제 조건**: Phase 7 (Secrets Manager 계정 경계 확립). Phase 8과 병렬 진행 가능.

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
