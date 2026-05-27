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
- [x] `terraform init && terraform apply` 실행

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
- [x] `terraform init` 실행 (`environments/develop/ap-northeast-2/shared/vpc/` 에서)
- [x] `terraform plan` 검토
- [x] `terraform apply` 실행

### 2-2. modules/eks + environments/dev eks 추가

- [ ] `modules/vpc/main.tf`에 ELB 서브넷 태그 추가
  - [ ] Public 서브넷: `kubernetes.io/role/elb = "1"`
  - [ ] Private 서브넷: `kubernetes.io/role/internal-elb = "1"`
- [ ] `modules/eks/variables.tf` 작성
- [ ] `modules/eks/main.tf` 작성
  - [ ] `terraform-aws-modules/eks v21.20.0` 호출
  - [ ] 엔드포인트 설정 (dev: Public+Private / prd: Private only)
  - [ ] 컨트롤 플레인 로깅 활성화 (API, Audit, Authenticator 등)
  - [ ] 시스템용 Managed Node Group 구성 (Karpenter 실행용)
    - [ ] Taint: `CriticalAddonsOnly=true:NoSchedule`
    - [ ] Label: `role: system`
    - [ ] `lifecycle { create_before_destroy = true }` 적용
  - [ ] Security Group Rule을 인라인 대신 별도 리소스로 분리
    - [ ] `aws_vpc_security_group_ingress_rule`
    - [ ] `aws_vpc_security_group_egress_rule`
- [ ] `modules/eks/outputs.tf` 작성 (cluster_name, endpoint, oidc_provider_arn 등)
- [ ] `environments/develop/ap-northeast-2/shared/eks/` 디렉토리 생성 및 구성 파일 작성
  - [ ] `providers.tf`, `backend.tf`, `data.tf`, `locals.tf`, `main.tf`, `outputs.tf`
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행

### 2-3. modules/karpenter + environments/dev karpenter 추가

- [ ] `modules/vpc/variables.tf`에 `cluster_name` variable 추가
- [ ] `modules/vpc/main.tf`에 Private 서브넷 Karpenter 탐색 태그 추가
  - [ ] `karpenter.sh/discovery = var.cluster_name`
- [ ] `modules/karpenter/variables.tf` 작성
- [ ] `modules/karpenter/main.tf` 작성
  - [ ] `terraform-aws-modules/eks//modules/karpenter` 서브모듈 사용
  - [ ] Karpenter 컨트롤러 IAM 역할 + 노드 인스턴스 프로파일
  - [ ] SQS + EventBridge (스팟 인터럽션 처리)
  - [ ] Karpenter Helm 차트 배포 (시스템 노드 그룹 대상)
  - [ ] `EC2NodeClass` 리소스 정의 (AMI Family: AL2023, Private 서브넷)
  - [ ] `NodePool` 리소스 정의
    - [ ] dev: spot + on-demand 혼합, TTL 30분
    - [ ] prd: on-demand 전용, TTL 60분
- [ ] `modules/karpenter/outputs.tf` 작성
- [ ] `environments/develop/ap-northeast-2/shared/eks/` 의 locals.tf에 karpenter 설정값 추가 후 모듈 호출
- [ ] `terraform plan` 검토
- [ ] `terraform apply` 실행

### 2-4. modules/eks-addons + environments/dev addons 추가

- [ ] `modules/eks-addons/variables.tf` 작성
- [ ] `modules/eks-addons/irsa.tf` 작성
  - [ ] `terraform-aws-modules/iam v6.6.0` 사용
  - [ ] AWS Load Balancer Controller용 IRSA 역할
  - [ ] EBS CSI Driver용 IRSA 역할
- [ ] `modules/eks-addons/main.tf` 작성 (EKS 관리형 애드온)
  - [ ] `aws_eks_addon` - `vpc-cni`
  - [ ] `aws_eks_addon` - `coredns`
  - [ ] `aws_eks_addon` - `kube-proxy`
  - [ ] `aws_eks_addon` - `aws-ebs-csi-driver`
  - [ ] `aws_eks_addon` - `eks-pod-identity-agent`
- [ ] `modules/eks-addons/helm.tf` 작성 (Helm 애드온)
  - [ ] AWS Load Balancer Controller
  - [ ] Metrics Server
  - [ ] kube-prometheus-stack (Prometheus + Grafana + AlertManager)
- [ ] `modules/eks-addons/outputs.tf` 작성
- [ ] `environments/develop/ap-northeast-2/shared/eks/` 의 locals.tf에 addons 설정값 추가 후 모듈 호출
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

## 기타

- [x] `.gitignore` 작성 (`.terraform/`, `*.tfstate`, `*.tfvars` 등)
- [ ] `README.md` 작성 (구조 설명, 사용 방법)
