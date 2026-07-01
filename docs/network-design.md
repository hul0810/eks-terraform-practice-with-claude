# 네트워크 설계 — VPC Peering (수동 관리)

## 배경

Phase 5(Observability 인프라)에서 monitoring 클러스터가 dev/prd 클러스터의
OTel Spoke Collector로부터 메트릭·트레이스를 수신하려면 VPC 간 사설 통신
경로가 필요하다.

원래 로드맵은 이 경로를 Transit Gateway(TGW)로 구축할 계획이었으나
(구 Phase 8), TGW 어태치먼트 비용(VPC당 ~$36/월, 3 VPC 기준 ~$108/월)이
이 프로젝트 규모에 비해 과도해 **비용 문제로 전면 취소**했다. VPC 3개
(monitoring↔dev, monitoring↔prd)로 연결 수가 적고, Hub(monitoring)만
spoke에 도달하면 되는 단방향 스타(hub-spoke) 구조라 애초에 transitive
라우팅(TGW의 핵심 장점)이 필요 없었다는 점도 취소 근거다. **VPC Peering이
이제 이 프로젝트의 영구적인 계정 간 네트워크 구성이다.**

## 계정 구조 (실측 확인, 2026-07-01 기준)

`monitoring/`은 로드맵상 Phase 7에서 정식 도입 예정인 Intra/Workload
2계정 분리보다 **먼저** 별도 AWS 계정으로 구축되어 있다. 즉 아래 상태는
현재 "1단계: 단일 계정" 서술과 이미 어긋나 있다 — Phase 7 진행 시 이
사실을 전제로 재설계해야 한다.

| 계정 | AWS Account ID | Terraform profile | 소속 VPC |
|------|----------------|--------------------|----------|
| monitoring | `157325288431` | `terraform-monitoring` | `eks-practice-mon` (10.12.0.0/16) |
| workload | `657231015203` | `terraform-workload` | `eks-practice-dev` (10.10.0.0/16), `eks-practice` prd (10.11.0.0/16) |

VPC ID (2026-07-01 조회):

| VPC | VPC ID | 계정 |
|-----|--------|------|
| monitoring | `vpc-01e56472a0ee9e65d` | monitoring |
| dev | `vpc-020daaa56936e1add` | workload |
| prd | `vpc-0d2e39a50aa18355d` | workload |

---

## 왜 Terraform이 아니라 AWS CLI로 관리하는가

VPC Peering이 **계정 간(cross-account)** 연결이므로 Terraform으로 구현하려면
Requester(monitoring)·Accepter(dev/prd) 양쪽 계정에 대한 provider를 각
root module에 추가하고, `aws_vpc_peering_connection` → `_accepter` →
route 추가까지 여러 리소스의 계정 간 순서 의존성을 관리해야 한다.

`modules/vpc/1.0.0`는 이 옵션(`vpc_peering_create`, `transit_gateway_id`
등)을 추가하는 계획이 TODO_LIST 5-1에 있었으나 실제로 구현된 적은 없다.
아래 이유로 모듈 확장 대신 **AWS CLI 수동 관리**로 전환했다.

- 연결 수가 2개(mon↔dev, mon↔prd)로 매우 적고 변경 빈도가 낮다.
- 계정 간 Terraform state 접근(cross-account assume)은 Phase 7에서
  `TerraformExecutionRole`을 재설계하며 함께 다룰 주제다. 지금 임시로
  선행 도입하면 Phase 7 재설계와 충돌한다.
- TGW 도입이 취소되어 VPC Peering이 영구 구성이 됐지만, 연결 수가 적다는
  점은 변하지 않으므로 여전히 AWS CLI 수동 관리가 IaC 비용 대비 합리적이다.

> 이 예외는 `CLAUDE.md`의 비용 최적화 예외 항목과 같은 성격의 **의도적
> 단순화**다.

---

## 연결 목록

| 이름 | Requester | Accepter | 상태 | PCX ID |
|------|-----------|----------|------|--------|
| mon-to-dev | monitoring (`vpc-01e56472a0ee9e65d`) | dev (`vpc-020daaa56936e1add`) | active (2026-07-01 생성) | `pcx-07fa1a0e9eb100e47` |
| mon-to-prd | monitoring (`vpc-01e56472a0ee9e65d`) | prd (`vpc-0d2e39a50aa18355d`) | active (2026-07-01 생성) | `pcx-084a197c6a2532991` |

`terraform.tfstate`가 없으므로 이 문서가 유일한 기록이다. 양쪽 private
라우팅 테이블(아래 "라우팅 설계" 표)에 라우트 추가까지 완료됨.

두 연결 모두 monitoring 계정이 Requester다 — Hub(monitoring)가 여러
Spoke(dev, prd)에 연결을 거는 hub-spoke 구조에서는 Hub 계정을 Requester로
두는 것이 관례다. 기능적으로는 방향이 반대여도 동작에 차이는 없다
(승인 후에는 완전히 대칭 동작). dev↔prd 간 직접 피어링은 만들지 않았다 —
Hub만 양쪽에 닿고 dev/prd는 서로 격리되는 구조를 유지한다.

---

## 라우팅 설계

OTel Spoke(DaemonSet, private subnet 노드)가 monitoring의 OTel Gateway
Internal NLB(private subnet)로 push하는 단방향 트래픽만 필요하다.
Public·Database 서브넷의 라우팅 테이블은 대상에서 제외한다.

| VPC | 라우팅 테이블 | 목적지 CIDR | 대상 |
|-----|---------------|-------------|------|
| dev | `eks-practice-dev-private` (`rtb-08eb05731242b2455`) | `10.12.0.0/16` | pcx (mon-to-dev) |
| prd | `eks-practice-private` (`rtb-0be72823552a5ee39`) | `10.12.0.0/16` | pcx (mon-to-prd) |
| monitoring | `eks-practice-mon-private` (`rtb-0691c857103a3cafe`) | `10.10.0.0/16` | pcx (mon-to-dev) |
| monitoring | `eks-practice-mon-private` (`rtb-0691c857103a3cafe`) | `10.11.0.0/16` | pcx (mon-to-prd) |

Security Group 인바운드 허용(OTel gRPC/HTTP 포트, 4317/4318)은 Phase 6에서
OTel Gateway를 GitOps로 배포할 때 함께 구성한다 — 이 문서의 범위는 VPC
간 라우팅까지다.

---

## 생성 절차 (runbook)

### 1. mon-to-dev 연결

```bash
# monitoring 계정에서 Requester 생성
aws ec2 create-vpc-peering-connection \
  --profile terraform-monitoring --region ap-northeast-2 \
  --vpc-id vpc-01e56472a0ee9e65d \
  --peer-vpc-id vpc-020daaa56936e1add \
  --peer-owner-id 657231015203 \
  --peer-region ap-northeast-2 \
  --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=mon-to-dev},{Key=managed_by,Value=manual-cli}]'
# 출력의 VpcPeeringConnectionId를 <PCX_DEV_ID>로 사용

# workload 계정에서 Accepter 승인
aws ec2 accept-vpc-peering-connection \
  --profile terraform-workload --region ap-northeast-2 \
  --vpc-peering-connection-id <PCX_DEV_ID>

# 라우트 추가 — dev private
aws ec2 create-route \
  --profile terraform-workload --region ap-northeast-2 \
  --route-table-id rtb-08eb05731242b2455 \
  --destination-cidr-block 10.12.0.0/16 \
  --vpc-peering-connection-id <PCX_DEV_ID>

# 라우트 추가 — monitoring private
aws ec2 create-route \
  --profile terraform-monitoring --region ap-northeast-2 \
  --route-table-id rtb-0691c857103a3cafe \
  --destination-cidr-block 10.10.0.0/16 \
  --vpc-peering-connection-id <PCX_DEV_ID>
```

### 2. mon-to-prd 연결

```bash
# monitoring 계정에서 Requester 생성
aws ec2 create-vpc-peering-connection \
  --profile terraform-monitoring --region ap-northeast-2 \
  --vpc-id vpc-01e56472a0ee9e65d \
  --peer-vpc-id vpc-0d2e39a50aa18355d \
  --peer-owner-id 657231015203 \
  --peer-region ap-northeast-2 \
  --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=mon-to-prd},{Key=managed_by,Value=manual-cli}]'
# 출력의 VpcPeeringConnectionId를 <PCX_PRD_ID>로 사용

# workload 계정에서 Accepter 승인
aws ec2 accept-vpc-peering-connection \
  --profile terraform-workload --region ap-northeast-2 \
  --vpc-peering-connection-id <PCX_PRD_ID>

# 라우트 추가 — prd private
aws ec2 create-route \
  --profile terraform-workload --region ap-northeast-2 \
  --route-table-id rtb-0be72823552a5ee39 \
  --destination-cidr-block 10.12.0.0/16 \
  --vpc-peering-connection-id <PCX_PRD_ID>

# 라우트 추가 — monitoring private
aws ec2 create-route \
  --profile terraform-monitoring --region ap-northeast-2 \
  --route-table-id rtb-0691c857103a3cafe \
  --destination-cidr-block 10.11.0.0/16 \
  --vpc-peering-connection-id <PCX_PRD_ID>
```

### 3. 확인

```bash
aws ec2 describe-vpc-peering-connections --profile terraform-workload --region ap-northeast-2 \
  --query 'VpcPeeringConnections[].{Id:VpcPeeringConnectionId,Status:Status.Code}'
```

`active` 상태 확인 후 "연결 목록" 표의 PCX ID를 갱신한다.

---

## 관련 문서

- `TODO_LIST.md` Phase 5-1/5-4 (진행 상태)
- `docs/project-structure.md` (State 파일 격리 원칙 — 이 피어링은 예외적으로 state 밖에서 관리됨)
