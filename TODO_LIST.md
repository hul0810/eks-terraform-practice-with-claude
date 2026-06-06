# EKS 인프라 구축 TODO LIST

## 진행 상황 범례
- [ ] 미완료
- [x] 완료
- [~] 진행 중

---

## Phase 1. 원격 상태 저장소 구성

> `global/tfstate-backend/` 디렉토리

- [x] `global/tfstate-backend/providers.tf` 작성 (AWS provider 설정)
- [x] `global/tfstate-backend/main.tf` 작성
  - [x] S3 버킷 생성 (버전 관리 + SSE-S3 암호화 + public access 차단)
  - [x] DynamoDB 테이블 생성 (PAY_PER_REQUEST, LockID 해시키)
- [x] `global/tfstate-backend/outputs.tf` 작성 (버킷명, 테이블명 출력)

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

- [ ] `modules/vpc/variables.tf`에 `cluster_name` variable 추가
- [ ] `modules/vpc/main.tf`에 Private 서브넷 Karpenter 탐색 태그 추가
  - [ ] `"karpenter.sh/discovery" = var.cluster_name`
- [ ] `environments/develop/ap-northeast-2/shared/eks-addons/karpenter.tf` 작성
  - [ ] `EC2NodeClass` 정의
    - [ ] AMI Family: AL2023
    - [ ] subnetSelectorTerms: `karpenter.sh/discovery = cluster_name` 태그 탐색
    - [ ] securityGroupSelectorTerms: `karpenter.sh/discovery = cluster_name` 태그 탐색
  - [ ] `NodePool` 정의
    - [ ] instanceCategory: c / m / r 계열
    - [ ] dev: Spot 우선 + On-Demand 혼합 (`capacity_type: [spot, on-demand]`)
    - [ ] disruption: consolidationPolicy=WhenEmptyOrUnderutilized, consolidateAfter=30s
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행
- [ ] `kubectl get ec2nodeclass` — NodeClass 등록 확인
- [ ] `kubectl get nodepool` — NodePool 등록 확인
- [ ] 테스트 Deployment 배포 후 Karpenter 앱 노드 프로비저닝 확인

---

## Phase 3. 환경 구성 (prd)

> dev 검증 완료 후 동일 패턴으로 구성

- [ ] `environments/production/ap-northeast-2/shared/vpc/` 구성 파일 작성
  - [ ] VPC CIDR: `10.11.0.0/16` (dev와 동일한 서브넷 타입별 그룹화 패턴 적용)
  - [ ] `azs = data.aws_availability_zones.available.names` (동적 조회)
  - [ ] `single_nat_gateway = false` (prd는 AZ당 1개 NAT GW)
  - [ ] `enable_nat_gateway = true`
- [ ] `environments/production/ap-northeast-2/shared/eks/` 구성 파일 작성
  - [ ] EKS endpoint: Private only
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행

---

## Phase 4. 검증

- [ ] `aws eks update-kubeconfig --name eks-practice-dev --region ap-northeast-2`
- [ ] `kubectl get nodes` - 시스템 노드 확인
- [ ] `kubectl get pods -A` - 전체 파드 상태 확인
- [ ] `kubectl get pods -n kube-system` - 관리형 애드온 확인
- [ ] `kubectl get pods -n karpenter` - Karpenter 동작 확인
- [ ] 테스트 Deployment 배포 후 Karpenter 노드 프로비저닝 확인

---

## Phase 5. GitOps 전환 (Terraform → ArgoCD)

> **목적**: 여러 환경·클러스터로 확장 시 반복 작업을 최소화하기 위해
> Helm 애드온 관리를 Terraform에서 ArgoCD로 이관한다.
>
> **전환 전제**: Phase 2-4 완료 후 진행. ArgoCD가 시스템 노드에 배포된 상태 기준.

### 5-1. ArgoCD 설치

- [ ] `modules/eks-addons/main.tf`에 ArgoCD Helm 설치 추가
  - [ ] `enable_argocd = true` (aws-ia/eks-blueprints-addons)
  - [ ] HA 구성 values 설정 (redis-ha, server replicas)
  - [ ] `CriticalAddonsOnly` toleration 추가 (시스템 노드에 스케줄)
- [ ] ArgoCD UI 접속 확인 (`kubectl port-forward svc/argocd-server -n argocd 8080:443`)

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

- [ ] `argocd/applicationsets/` 디렉토리 생성
- [ ] `argocd/applicationsets/eks-addons.yaml` 작성
  - [ ] Generator: 환경 목록 (`develop`, `production`)
  - [ ] 공통 Chart 버전 선언 (LBC, kube-prometheus-stack)
  - [ ] 환경별 values 파일 경로 연결 (`values-{{env}}.yaml`)
- [ ] `argocd/values/` 디렉토리 생성
  - [ ] `values-develop.yaml` — dev 환경 오버라이드 (replica 수, resource limits 등)
  - [ ] `values-production.yaml` — prd 환경 오버라이드

### 5-4. Karpenter GitOps 전환

- [ ] `modules/karpenter/main.tf`에 `create_kubernetes_resources = false` 추가
  - Terraform: IAM Role + SQS + EventBridge만 유지
  - ArgoCD: Karpenter Helm Chart + EC2NodeClass + NodePool 관리
- [ ] `argocd/applicationsets/karpenter.yaml` 작성

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
