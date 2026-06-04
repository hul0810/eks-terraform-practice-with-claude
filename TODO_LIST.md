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

### 2-3. modules/eks-addons + environments/dev addons 추가

> **순서 중요**: eks-pod-identity-agent는 modules/eks(2-2)에서 이미 설치됨.
> 이 모듈에서 eks-pod-identity-agent 중복 선언 금지.
>
> 전략: 관리형 우선 (`docs/addon-strategy.md` 참조)
> - AWS 관리형이 있는 것: `aws_eks_addon` 직접 선언
> - 관리형 없는 것만: `aws-ia/eks-blueprints-addons` Helm 래핑 사용

- [ ] `modules/eks-addons/variables.tf` 작성
- [ ] `modules/eks-addons/main.tf` 작성
  - [ ] **EKS 관리형 (`aws_eks_addon` 직접 선언, Pod Identity IAM 포함)**
    - [ ] `aws-ebs-csi-driver` — IAM: `AmazonEBSCSIDriverPolicy`
    - [ ] `metrics-server` — IAM 불필요 (Community 관리형)
    - [ ] `external-dns` — IAM: Route53 권한 (Community 관리형)
  - [ ] **Helm 전용 (`aws-ia/eks-blueprints-addons ~> 1.21`)**
    - [ ] `enable_aws_load_balancer_controller = true` — IAM: `AWSLoadBalancerControllerIAMPolicy`
    - [ ] `enable_kube_prometheus_stack = true`
- [ ] `modules/eks-addons/outputs.tf` 작성
- [ ] `environments/develop/ap-northeast-2/shared/eks/main.tf`에 `module "eks_addons"` 추가
  - [ ] `depends_on = [module.eks]` 명시
  - [ ] `providers.tf`에 `helm`, `kubernetes` provider 추가
  - [ ] 초기 구축 순서 주석 추가: `terraform apply -target=module.eks` 먼저
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행

### 2-4. modules/karpenter + environments/dev karpenter 추가

> **전제**: 2-3 eks-addons 완료 후 진행 (eks-pod-identity-agent 설치 완료 상태)

- [ ] `modules/vpc/variables.tf`에 `cluster_name` variable 추가
- [ ] `modules/vpc/main.tf`에 Private 서브넷 Karpenter 탐색 태그 추가
  - [ ] `karpenter.sh/discovery = var.cluster_name`
- [ ] `modules/karpenter/variables.tf` 작성
- [ ] `modules/karpenter/main.tf` 작성
  - [ ] `aws-ia/eks-blueprints-addons ~> 1.21` 사용
    (Karpenter IAM Role + SQS 인터럽션 큐 + EventBridge Rule 4개 + Helm 배포 통합 처리)
  - [ ] `enable_karpenter = true` 플래그 활성화
  - [ ] `EC2NodeClass` 리소스 정의 (AMI Family: AL2023, Private 서브넷)
  - [ ] `NodePool` 리소스 정의
    - [ ] dev: spot + on-demand 혼합, TTL 30분
    - [ ] prd: on-demand 전용, TTL 60분
- [ ] `modules/karpenter/outputs.tf` 작성
- [ ] `environments/develop/ap-northeast-2/shared/eks/main.tf`에 `module "karpenter"` 추가
  - [ ] `depends_on = [module.eks_addons]` 명시
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행

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
- [ ] `kubectl get pods -n monitoring` - Prometheus/Grafana 확인
- [ ] 테스트 Deployment 배포 후 Karpenter 노드 프로비저닝 확인
- [ ] Grafana 대시보드 접속 확인

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

## 기타

- [x] `.gitignore` 작성 (`.terraform/`, `*.tfstate`, `*.tfvars` 등)
- [ ] `README.md` 작성 (구조 설명, 사용 방법)
