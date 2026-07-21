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
>
> **우선순위 하향 (2026-07-21)**: Phase 6-5(Hub-Spoke ArgoCD 확장 — dev/prd를 spoke로 등록)를
> 먼저 진행한다. monitoring 쪽 ArgoCD Hub 구축과 devops-manifest 연동이 이미 완료된 상태라,
> 그 구조를 실제 멀티 클러스터 환경(dev/prd 포함)에서 검증하는 게 더 급하다고 판단했다 —
> Phase 5의 나머지 항목(5-4/5-5)은 6-5 완료 후로 미룬다.

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

> **목표**: 2계정(monitoring/workload) 분리 구조 위에 Hub-Spoke GitOps, Organizations
> 거버넌스, 중앙 Observability, 보안 정책을 적용해 1단계를 실무 엔터프라이즈 수준으로
> 끌어올린다.
>
> **진행 순서**: Phase 6(ArgoCD Hub GitOps) → Phase 7(Organizations 거버넌스) →
> Phase 8(중앙 Observability) / Phase 9(보안 거버넌스, Phase 7 이후 병렬 가능)
>
> **네트워크**: 계정 간 연결은 Transit Gateway 대신 VPC Peering(AWS CLI 수동 관리,
> `docs/network-design.md`)을 쓴다 — 연결 수가 2개뿐이라 TGW 어태치먼트 비용을 들일
> 이유가 없었다.

---

### Phase 6. Hub-and-Spoke ArgoCD + GitOps Bridge (중앙 GitOps)

> **목표**: dev/prd 개별 ArgoCD를 걷어내고, monitoring 계정의 기존 ArgoCD를 Hub로 삼아
> spoke(dev/prd)를 원격 관리하는 Hub-and-Spoke 구조로 전환한다. addon의 Helm 관리 주체를
> Terraform → ArgoCD로 넘기되, addon이 참조하는 IAM 등 AWS 리소스는 계속 Terraform이 관리한다.
>
> **GitOps Bridge 패턴** ([gitops-bridge-dev/gitops-bridge](https://github.com/gitops-bridge-dev/gitops-bridge)):
> Terraform이 만든 IAM Role ARN 등을 ArgoCD `cluster` Secret의 annotation에 적어두면,
> ApplicationSet의 `cluster generator`가 이를 읽어 각 addon Helm values(예:
> `serviceAccount.annotations.eks.amazonaws.com/role-arn`)에 자동 주입한다 — Terraform과
> ArgoCD를 잇는 다리.
>
> **ArgoCD 자신은 예외적으로 계속 Terraform이 설치**: Hub-Spoke 구조 자체가 ArgoCD를
> 전제로 하므로 ArgoCD 설치를 ArgoCD로 관리할 수 없다(부트스트랩 역설). 실제 구현은
> `modules/eks-addons/2.0.0`의 `gitops_bridge_bootstrap` 인스턴스
> (`gitops-bridge-dev/gitops-bridge/helm`).
>
> **왜 중앙 집중인가**:
> - 운영 표면 1/N 감소 — ArgoCD를 클러스터마다 개별 운영하지 않고 Hub 1곳에서 업그레이드·RBAC·백업 관리
> - 환경 일관성 — 동일 ApplicationSet의 cluster generator가 dev/prd에 동일 Chart를 배포해 버전 드리프트 구조적 차단
> - 승격(Promotion) 워크플로 — Hub 한 곳에서 dev→prd 배포를 가시화·게이팅
> - 보안 표면 축소 — spoke에는 ArgoCD가 없어 공격 표면이 Hub로 집중
>
> **SPOF 검토**: Hub 장애 시에도 이미 배포된 워크로드는 정상 동작한다(ArgoCD는
> reconciler이지 데이터 플레인이 아니다) — 관리 평면만 정지, 데이터 평면은 무중단.
>
> **전제 조건**: Phase 4(ArgoCD 설치), Phase 5-3(monitoring 클러스터 존재)

**6-1. GitOps Bridge 개념 실습 — monitoring 자기 자신 대상 (완료, 2026-07-17)**
- [x] ArgoCD `cluster` Secret 구조 파악, monitoring이 자기 자신을 가리키는 Secret을 Terraform으로 생성
- [x] `argocd-application-controller`에 IRSA + EKS Access Entry + 읽기 전용 ClusterRole 구성
- [x] 테스트 Application으로 실제 배포 검증(읽기 성공, 쓰기 차단 — least-privilege 정상 동작)

**6-2. 애드온 파일럿 전환 — metrics-server (완료, 2026-07-17)**
- [x] IAM 불필요·상태 없는 metrics-server를 Terraform Helm → ArgoCD Application으로 무중단 이관
- [x] `modules/eks-addons/2.0.0` 신설(ArgoCD 전용 인스턴스와 나머지 분리) — `1.0.0`은 원본 유지

**6-3. IAM 필요 애드온 전환 — aws-load-balancer-controller (완료, 2026-07-17)**
- [x] LBC의 IAM은 Terraform 유지, Helm release만 ArgoCD로 이관
- [x] `create_kubernetes_resources=false` 고정된 `eks_blueprints_addons_gitops` 인스턴스 신설(이후 addon 전용 재사용)
- [x] Helm chart webhook 인증서 비결정성 문제 대응 패턴 확립 —
  `ignoreDifferences` + `syncOptions: [RespectIgnoreDifferences=true]` + 배열 전체 커버용 `jqPathExpressions`

**6-4. 나머지 monitoring 애드온 순차 전환 (완료)**
- [x] argo-rollouts(2026-07-17) — CRD가 `kubectl apply`의 256KB annotation 제한에 걸려 `ServerSideApply=true` 필요
- [x] karpenter(2026-07-18) — 컨트롤러 IRSA·노드 IAM Role·SQS·EventBridge까지 이관
- [x] external-dns(2026-07-18) — cross-account assume-role 유지
- [x] external-secrets(2026-07-18) — CRD 일부(658KB) `ServerSideApply=true` 필요
- [x] argocd-image-updater + git-creds(2026-07-18)
- [x] ClusterSecretStore/ExternalSecret 전체(2026-07-18) — IAM/ServiceAccount는 Terraform 유지
- [x] Karpenter NodeClass/NodePool(2026-07-18) — plain-manifest Application(이 저장소 최초 non-Helm 소스)

  **부수 발견**:
  - ArgoCD 부트스트랩 순환 의존: repo-creds Secret이 ESO 경유였는데, ESO 자체도 GitOps
    대상이면 "ArgoCD가 떠야 ESO가 뜨고, ESO가 떠야 ArgoCD가 뜬다"는 순환이 생김 —
    Terraform이 SSM을 직접 읽어 Secret을 만드는 방식으로 전환해 해소
  - `enable_argo_rollouts=false`가 ArgoCD UI의 rollout-extension 표시 여부에도 재사용되고
    있어 이관 후 조용히 꺼질 뻔함 — `argo_rollouts_extension_enabled` 변수로 분리
  - Karpenter `clusterEndpoint` 하드코딩 때문에 재구축 후 신규 노드가 조인 못 하는 문제 —
    값을 비우고 `eksControlPlane=true`로 전환해 런타임에 스스로 조회하도록 수정

  **이관 완료 목록**: LBC, metrics-server, argo-rollouts, karpenter(+NodeClass/NodePool),
  external-dns, external-secrets, argocd-image-updater(+git-creds), ClusterSecretStore.
  **영구 Terraform 예외**: ArgoCD 자신(Helm), ArgoCD repo-creds, ArgoCD 자신의 cluster Secret.

**6-4 이후 — ArgoCD 설치 모듈 교체 (완료, 2026-07-19)**
- [x] ArgoCD 설치 주체를 blueprints에서 `gitops-bridge-dev/gitops-bridge/helm`로 교체 —
  blueprints wrapper가 ArgoCD 자리에서 IRSA 인자를 forward하지 않는 결함 발견
- [x] `gitops_bridge_hub`(nullable) 변수로 Hub-Spoke opt-in 설계, `terraform state mv`로 무중단 전환
- [x] devops-manifest가 addon 10개를 `clusters` generator 기반 ApplicationSet으로 전환 —
  메타데이터 브릿지 annotation 실사용 시작

**6-4 이후 — "rest" 인스턴스 삭제, GitOps Bridge 전용 구조로 정리 (완료, 2026-07-20)**
- [x] IAM 불필요 addon(metrics-server/argo-rollouts)을 임시로 담아두던 "rest" 인스턴스 완전
  삭제 — 이후 IAM 불필요 addon은 Terraform이 처음부터 관여하지 않음
- [x] 무의미해진 변수 6개·dead local(~280줄) 제거, `replica_counts` 스키마 7필드 → 1필드로 축소
- [x] `main.tf`(1057줄)를 `main.tf`/`locals.tf`/`notifications.tf` 3개로 분리
- 부수 발견: devops-manifest ApplicationSet 4종에 `CreateNamespace=true` 누락 — monitoring을
  처음부터 재구축하면 sync 실패 가능. 요청서 전달, 미반영

**6-4 이후 — `gitops-bridge-irsa.tf`의 monitoring-self Access Entry+RBAC 완전 제거(완료, 2026-07-21)**
> 원래는 "IRSA → Pod Identity 전환"으로 백로그에 있었으나, 검토 과정에서 그 인증 체인
> 자체가 안 쓰이고 있다는 걸 확인해 전환이 아니라 제거로 방향을 바꿨다.

- [x] CloudTrail + application-controller 로그로 실측 — monitoring 자신을 대상으로 하는
  모든 Application이 `destination: name: in-cluster`(ArgoCD 내장 자격증명)를 쓰고 있어,
  이 IRSA Role의 Access Entry+RBAC 경로로 monitoring 자신의 EKS API에 접근한 기록이
  전혀 없음을 확인
- [x] vendor 모듈(gitops-bridge-dev/gitops-bridge/helm) 소스 확인 — `cluster.server`/
  `cluster.config`를 안 넘기면 `server=https://kubernetes.default.svc`,
  `config={tlsClientConfig:{insecure:false}}`(awsAuthConfig 없음)로 자동 대체됨을 확인
- [x] `aws_eks_access_entry.argocd_hub_self` + `kubernetes_cluster_role.argocd_read_all` +
  `kubernetes_cluster_role_binding.argocd_read_all` 3개 리소스 삭제, cluster Secret의
  `server`/`config` 필드 제거(vendor 기본값 사용). `aws_iam_role.argocd_application_controller`는
  dev/prd spoke를 sts:AssumeRole하는 데 여전히 쓰이므로 유지
- [x] apply 후 monitoring/dev addon Application 18개 전부 Synced/Healthy 유지 확인(회귀 없음)
- 상세 경위: `temp/gitops-bridge-root-app-bootstrap.md`

**6-5. Hub-Spoke 확장 — dev/prd를 spoke로 등록 (dev 완료·검증, prd는 코드만 — 2026-07-21)**
- [x] dev/prd EKS Access Entry에 Hub ArgoCD의 IAM Role 등록
  - 부수 발견: spoke Role의 신뢰 정책만으로는 부족 — Hub Role 쪽에도 "무엇을 assume할 수
    있는가"를 허용하는 identity policy가 별도로 필요(`AccessDenied`로 실제 발견)
  - 부수 발견: dev EKS API의 `public_access_cidrs`가 운영자 IP만 허용해 monitoring NAT
    Gateway IP가 차단됨 — CIDR에 추가해 해결(장기적으로는 private access + 기존 VPC
    Peering 경유가 더 안전, 백로그로 기록)
- [x] dev/prd cluster Secret을 monitoring ArgoCD 네임스페이스에 생성(`for_each` 기반,
  prd는 `enabled=false`로 실제 조회 자체가 안 일어남)
  - 부수 발견: cluster Secret이 생기자마자 addon selector가 너무 넓어 `-dev` Application이
    자동 생성되고 monitoring 자신과 리소스 소유권이 충돌(`SharedResourceWarning`) —
    devops-manifest에 구분 라벨(`eks-practice.io/gitops-bridge-role: spoke`) 기반 selector
    스코프 분리 요청, 반영 완료
- [x] dev/prd `eks-addons`에서 개별 `enable_argocd` 제거(dev는 helm_release destroy까지 확인)
- [x] dev 검증 — 임시 테스트 Application으로 sync 성공, 리소스가 실제 dev 클러스터에 생성됨을 확인

**6-5 이후 — dev/prod addon Helm 관리 주체를 Terraform → ArgoCD로 완전 이관 (완료, 2026-07-21)**
> 6-5는 "Hub가 dev/prd에 접근 가능한" 연결 레이어까지였다. dev/prd 자체는 여전히 addon Helm을
> Terraform이 직접 설치하는 `1.0.0`이라, monitoring이 거친 이관(6-2~6-4)을 dev/prd에도 적용해야
> Hub가 실제로 addon을 원격 배포할 수 있다.

- [ ] devops-manifest에 addon selector 포함 요청 — `eks-practice.io/addon-managed: "true"` 라벨 기반 반영 (2026-07-22 재확인: devops-manifest의 `-spoke` ApplicationSet 어디도 이 라벨을 selector로 안 씀, `temp/gitops-bridge-addon-managed-label-unused-gap.md`)
- [x] metrics-server/argo-rollouts — sync 확인 후 `terraform state rm` + `enable_*=false`로 Terraform 손 뗌.
  pod RESTARTS=0으로 무중단 인수 확인
- [x] LBC/Karpenter/ExternalDNS/ExternalSecrets — IAM Role ARN 등 7개 annotation을 dev cluster
  Secret에 추가해 sync 성공, 무중단 인수 확인
- [x] dev `eks-addons` root를 `2.0.0`으로 전환 — IAM 리소스 26개 `terraform state mv`, Helm
  release 4개 `terraform state rm`. 단일 apply, `plan` = "No changes" 확인
- [x] Karpenter NodeClass/NodePool(general/arm64/gpu/spot) — devops-manifest가 karpenter-resources
  차트로 이관하는 과정에서 Terraform과 ArgoCD가 같은 NodePool을 동시에 server-side-apply로
  소유하는 필드 매니저 충돌을 실제로 발견(`limits.cpu`가 두 값 사이를 오감) — ArgoCD 쪽
  스펙이 Terraform과 동등하거나 더 안전함을 확인 후 `terraform state rm` + 코드 제거,
  ArgoCD 단독 관리로 전환
- [x] dev 전체 검증 — 파드 전부 Running/Completed, addon Application 전부 Synced/Healthy
  (karpenter-resources-dev만 조직 SCP 관련 `RunInstancesAuthCheckFailed`로 Degraded 표시,
  실제 노드/파드는 정상 — 논블로킹)
- [x] production 동일 패턴 코드 작성(apply는 보류, CLAUDE.md Production 배포 정책)

**백로그**
- [ ] prod를 실제 프로비저닝하기 전 monitoring `gitops-bridge-spokes.tf`에서 prod를
  spoke+addon_managed로 먼저 활성화해야 함 — 안 하면 addon Helm이 전혀 안 깔린 채 fresh
  apply될 위험(`/env-provision` 스킬에 가드 추가 완료)

**6-5 이후 — root-app-addons ApplicationSet 부트스트랩 자동화(완료, 2026-07-21)**
> `env-provision` 스킬 Step 3-B-2가 사람이 수동으로 `gh api ... | kubectl apply -f -`로
> 적용해야 했던 `root-app-addons`를, monitoring 클러스터 생성 시 Terraform이 자동으로
> 만들도록 전환했다.

- [x] `bootstrap/root-app-addons.yaml`(ApplicationSet, Hub의
  `gitops_bridge_hub.apps.addons`로 전달) 신설 — repoURL/path/revision은 하드코딩하지
  않고 `{{metadata.annotations.addons_repo_url}}` 등으로 cluster Secret annotation에서
  읽음(실제 값은 `gitops-bridge-irsa.tf`의 `local.gitops_bridge_hub_cluster.metadata`가
  소유). `clusters` generator selector를 Hub 자신(`cluster_name: monitoring-self`)에만
  매칭시켜 dev/prd spoke까지 중복 매칭되는 것을 방지
- [x] devops-manifest의 실제 addon 매니페스트는 여전히 Terraform이 전혀 읽지 않음 —
  이 root가 갖는 건 "어디를 보라"는 포인터뿐(`docs/addon-strategy.md` 경계 유지),
  gitops-bridge-dev/gitops-bridge 공식 예제와 동일 패턴(vendor 저장소로 검증)
- [x] `terraform fmt`/`validate` 통과 확인(monitoring 클러스터가 꺼져있어 실제 `plan`은
  다음 `/env-provision monitoring` 때 최초 검증)
- 부수 발견: 워크로드(catalog/gateway/order) Application까지 같이 자동 부트스트랩할지
  검토했으나 보류 — vendor 예제도 갈린다(`multi-cluster/hub-spoke`는 addons+workloads를
  같이 부트스트랩, `multi-cluster/hub-spoke-shared`는 addons만). 인프라 프로비저닝과
  워크로드 배포는 라이프사이클이 다르다고 판단해 addons만 이 root가 담당하고, workload
  부트스트랩 방식은 Phase 6-6 착수 시점에 별도 결정하기로 함
- [x] devops-manifest에 `argocd/projects/workload.yaml`(AppProject)을
  `argocd/applicationsets/workload/_project.yaml`로 이동 요청 — 반영 완료 확인(2026-07-21,
  GitHub에서 새 경로 존재·옛 경로 404 직접 확인)
- [x] 버그 수정: `destination: server: '{{server}}'` → `name: in-cluster`(devops-manifest
  리뷰로 발견, 2026-07-21) — `clusters` generator가 매칭하는 `monitoring-self`는 Phase
  6-1에서 의도적으로 읽기 전용 RBAC로 구성해뒀는데, 이걸 destination에 그대로 쓰면 이
  Application이 만드는 하위 addon ApplicationSet들의 write가 전부 막혀 sync가 실패했을
  것. devops-manifest의 실제 addon ApplicationSet들이 이미 같은 이유로 `in-cluster` 고정
  패턴을 쓰고 있었음 — clusters generator는 annotation 값을 읽어오는 용도로만 남기고
  destination은 그 패턴을 그대로 따름

**백로그 (aws-architect 리뷰, 2026-07-21)**
- [x] `env-teardown` 스킬이 Terraform 소유가 된 `root-app-addons` 부트스트랩을 인지 못하던
  문제 — Step 2(과거 "실행 안 함"으로 비활성화)를 재활성화해 Step 3(Ingress 수동 삭제)
  전에 `kubectl delete application/applicationset --all -n argocd`로 ArgoCD의 능동
  조정(selfHeal)을 먼저 끊도록 수정. Step 6에는 root-app-addons가 이미 Step 2에서
  지워진 상태로 도달한다는 참고와 `terraform state rm` 우회법을 추가
- [ ] 라이브 클러스터에 이미 수동 kubectl apply된 동일 이름 `root-app-addons`가 있는
  상태로 이 변경을 처음 적용하면 Helm이 소유권 충돌로 실패할 수 있음(fresh
  destroy→재생성 경로에서는 해당 없음 — 선존 리소스가 없으므로) — 라이브 클러스터에
  얹을 일이 생기면 `kubectl delete applicationset root-app-addons -n argocd` 선행 필요
- [ ] root-app-addons의 `syncPolicy.automated.prune: true`가 최상단에 걸려있어
  `addons_repo_path`/`revision` annotation 오타나 devops-manifest 경로 일시 공백 시
  하위 addon ApplicationSet 전체가 prune될 수 있음(선택 사항 — `prune: false` 전환 검토)

**6-5 이후 — 라이브 검증: monitoring 단독/dev 등록 시 addon 자동 배포 확인(완료, 2026-07-21)**
> 목표 2가지를 실제 `terraform apply`로 검증했다 — (1) monitoring만 apply해도
> root-app-addons가 자동으로 18개 addon ApplicationSet을 만들고 sync까지 되는가,
> (2) dev를 spoke로 등록하면 `-spoke` ApplicationSet들이 자동으로 dev에 addon을
> 배포하는가. `kubectl apply`/`argocd app sync`를 손으로 한 번도 안 돌리고 둘 다 확인됨
> (monitoring: 11개 Application 자동 sync, dev: 7개 자동 생성·sync).

- [x] `env-provision` 스킬의 `-target=module.eks_addons` 선행 apply가 더 이상 안 먹힘 —
  `gitops_bridge_bootstrap`의 `count = var.create && (var.cluster != null) ? 1 : 0`이
  target 범위 밖 리소스(`aws_iam_role.argocd_image_updater`)를 참조해 "Invalid count
  argument"로 막힘. `eks_blueprints_addons_gitops` 모듈 + `aws_iam_role.argocd_image_updater`를
  먼저 target apply해 ARN을 확정한 뒤 전체 apply하는 2단계로 우회 — 스킬 문서 갱신 필요
- [x] dev `public_access_cidrs`의 monitoring NAT Gateway IP 하드코딩 문제가 실제로
  재현됨(백로그에 이미 예견돼 있던 것) — monitoring 재생성으로 IP가 바뀌자 Hub→dev
  ExternalDNS/ArgoCD 인증이 실제로 끊겼고, IP를 갱신해 해결
- [x] `env-provision` Step 4(cross-account ExternalDNS 신뢰 정책 갱신)를 이번 monitoring
  프로비저닝에서 누락해 `argocd.pyhtest.com` Route53 레코드가 아예 안 생기는 문제로
  이어짐 — ExternalDNS가 workload 계정 Role에 `sts:AssumeRole` 거부당함(재생성으로 새
  unique ID를 받았는데 trust policy가 옛 ID 그대로였음). `external-dns-cross-account-role`
  root apply로 해결
- [x] dev의 Karpenter가 조직 SCP `RunInstancesAuthCheckFailed`로 NodePool 전체
  "not ready" 판정을 받아 노드 프로비저닝 자체가 완전히 막힘(monitoring은 같은 조건에서
  cosmetic 수준이었는데 dev는 실제로 막힘) — CloudTrail로 원인 추적: `general` NodePool만
  `instance-size` 상한이 있고 `arm64`/`gpu`/`spot`은 상한이 없어 Karpenter의 IAM
  dry-run 검증(`DryRun=true`, 과금 없음)이 대형 인스턴스(`m7gd.12xlarge`)를 후보로
  잡아버림 — devops-manifest에 상한 추가 + 클러스터별 NodePool 선택 구성 요청 전달
- [x] devops-manifest 회신 반영 — dev cluster Secret에 `karpenter_nodepool_arm64_enabled`/
  `gpu_enabled`/`spot_enabled` annotation 3개 추가(전부 "true", 워크로드는 4종 전체
  사용). monitoring은 이 값 자체를 안 받음(GPU 불필요, devops-manifest
  values-override.yaml에서 기본 false 고정)
- 부수 발견: monitoring-self의 IRSA Role+Access Entry+읽기 전용 ClusterRole(Phase 6-1)이
  실제로는 안 쓰이고 있을 가능성 — self 대상 Application들이 `destination: name:
  in-cluster`(ArgoCD 자신의 내장 자격증명)를 쓰므로 Secret의 `config.awsAuthConfig`(그
  IRSA Role을 가리킴) 경로 자체가 참조되지 않음. cluster Secret 자체(metadata/label)는
  annotation 브릿지 때문에 필요하지만, 그 뒤에 딸린 인증 체인은 불필요할 수 있음 — 6-4
  이후 백로그의 "IRSA → Pod Identity 전환" 항목을 "이 인증 체인 자체가 필요한가"로
  재검토할 필요

**6-6. GitOps 저장소 구조화 및 애플리케이션 배포**
> devops-manifest의 workload(catalog/gateway/order) ApplicationSet은 이미 `clusters`
> generator 기반으로 코드 전환됐지만, 그 진입점(`root-app-workload.yaml`)이 Hub에
> 부트스트랩된 적이 없어 아직 라이브 검증 전이다 — 이 Phase에서 부트스트랩과 실배포를 확인한다.

- [ ] `eks-practice-devops-manifest` repo에 ApplicationSet 작성(애드온 values + MSA 배포 매니페스트)
- [ ] App-of-Apps로 dev/prd 애드온 전체를 6-1~6-4 패턴대로 원격 배포
- [ ] MSA 애플리케이션(`eks-practice-application-with-claude`) ArgoCD Application 등록, dev 배포 확인
- [ ] Hub 장애 시 spoke 워크로드 정상 동작 검증(SPOF 아님 확인)
- [ ] GitHub Actions CI/CD: 이미지 빌드 → ECR push → ArgoCD Image Updater/Argo Rollouts 배포 루프
  - [ ] OIDC 기반 ECR 접근(IAM User 장기 키 제거)

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
