# 프로젝트 폴더 구조

## 설계 목표

| 목표 | 설명 |
|------|------|
| 멀티 프로젝트 지원 | `project/`, `project-b/` 등 최상위 프로젝트 단위로 독립 관리 |
| 리전 독립 배포 | 동일 환경을 여러 리전에 배포 가능 |
| 리소스별 State 격리 | VPC, EKS, RDS 등 리소스 타입마다 독립 Terraform state |
| 서비스별 분리 | `shared` (공용 인프라) / `api`, `payment` 등 워크로드별 독립 관리 |
| 환경 분리 | `develop` / `production` 완전 분리, 코드는 동일한 `modules/`를 재사용 |

---

## 디렉토리 레이아웃

아래는 현재 구조와 향후 확장 예시를 함께 나타낸 전체 레이아웃이다.

```
terraform-eks-practice/
│
├── docs/                                   # 프로젝트 문서
│   └── project-structure.md
│
├── global/                                 # 환경·프로젝트 무관 글로벌 인프라
│   └── tfstate-backend/                    # S3 버킷 + DynamoDB (state 저장소)
│
├── modules/                                # 전체 프로젝트 공용 재사용 Terraform 모듈 (중앙 집중식)
│   ├── vpc/
│   │   └── 1.0.0/                          # 버전 디렉토리 (인터페이스 변경 시 2.0.0/ 추가)
│   ├── eks/
│   │   └── 1.0.0/
│   ├── karpenter/                          # (예정)
│   │   └── 1.0.0/
│   └── eks-addons/                         # (예정)
│       └── 1.0.0/
│
├── project/                                # 프로젝트 네임스페이스 (신규 프로젝트는 project-b/ 등으로 추가)
│   └── environments/
│       ├── develop/
│       │   └── ap-northeast-2/             # 리전
│       │       ├── shared/                 # 모든 서비스 공용 인프라
│       │       │   ├── vpc/                # ← root module
│       │       │   ├── eks/                # ← root module
│       │       │   ├── eks-addons/         # ← root module
│       │       │   └── tgw/                # (예정)
│       │       ├── msa/                    # MSA 서비스 전용 인프라
│       │       │   └── ecr/                # ← root module (이미지 저장소)
│       │       ├── api/                    # 워크로드별 인프라 (예정)
│       │       │   ├── eks/
│       │       │   └── rds/
│       │       └── payment/                # 워크로드별 인프라 (예정)
│       │           └── eks/
│       └── production/
│           └── ap-northeast-2/
│               └── shared/
│                   └── vpc/                # (예정)
│
└── project-b/                              # (예정) 추가 프로젝트 예시
    └── environments/
```

각 `{resource}/` 디렉토리(예: `vpc/`, `eks/`)가 독립적인 Terraform root module이다.

---

## 계층별 역할

| 레이어 | 예시 | 역할 |
|--------|------|------|
| `{project}` | `project`, `project-b` | 최상위 프로젝트 단위. 독립 modules/와 environments/를 소유 |
| `{env}` | `develop`, `production` | 환경 분리. 서로 다른 AWS 계정 또는 동일 계정 내 격리 |
| `{region}` | `ap-northeast-2` | 리전별 독립 배포 지원. 멀티 리전 확장 시 디렉토리 추가만으로 대응 |
| `{service}` | `shared`, `api`, `payment` | 워크로드/팀 단위 분리. `shared`는 VPC·TGW 등 공용 인프라 |
| `{resource}` | `vpc`, `eks`, `rds` | 리소스 타입별 독립 state. 변경 범위를 최소화하고 blast radius를 줄임 |

---

## State 파일 격리

각 `{resource}/` 디렉토리는 독립 Terraform root module이며 고유한 S3 state 파일을 가진다.

**S3 key 패턴**: `{project-short}/{env}/{region}/{service}/{resource}/terraform.tfstate`

> `project-short`: 프로젝트 디렉토리명과 같은 짧은 식별자. `project` → `project`, `project-b` → `project-b`

| root module 경로 | state key |
|------------------|-----------|
| `project/environments/develop/ap-northeast-2/shared/vpc/` | `project/develop/ap-northeast-2/shared/vpc/terraform.tfstate` |
| `project/environments/develop/ap-northeast-2/shared/eks/` | `project/develop/ap-northeast-2/shared/eks/terraform.tfstate` |
| `project/environments/develop/ap-northeast-2/shared/eks-addons/` | `project/develop/ap-northeast-2/shared/eks-addons/terraform.tfstate` |
| `project/environments/develop/ap-northeast-2/msa/ecr/` | `project/develop/ap-northeast-2/msa/ecr/terraform.tfstate` |
| `project/environments/develop/ap-northeast-2/api/eks/` | `project/develop/ap-northeast-2/api/eks/terraform.tfstate` |
| `project/environments/production/ap-northeast-2/shared/vpc/` | `project/production/ap-northeast-2/shared/vpc/terraform.tfstate` |
| `project-b/environments/develop/ap-northeast-2/shared/vpc/` | `project-b/develop/ap-northeast-2/shared/vpc/terraform.tfstate` |

---

## Cross-layer 출력값 참조

상위 레이어의 출력값이 필요할 때 `terraform_remote_state` 데이터 소스를 사용한다.
`outputs.tf`에서 노출한 값만 참조할 수 있으므로, 공유가 필요한 값은 반드시 output으로 선언해야 한다.

**예시**: `shared/eks/` 에서 `shared/vpc/` 의 VPC ID, 서브넷 ID 참조

```hcl
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket  = "eks-practice-tfstate-MGMT_ACCOUNT_ID"
    key     = "project/develop/ap-northeast-2/shared/vpc/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "terraform"
    assume_role = {
      role_arn = "arn:aws:iam::MGMT_ACCOUNT_ID:role/TerraformExecutionRole"
    }
  }
}

locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
}
```

---

## module source 경로 규칙

root module에서 루트 `modules/`를 참조할 때 상대경로 깊이는 항상 6단계(`../../../../../../`)이다.

```
project/environments/{env}/{region}/{service}/{resource}/main.tf
                                                         ↑ 현재 위치
6단계 상위 = 저장소 루트
../../../../../../modules/{name}/{version}  →  modules/{name}/{version}
```

```hcl
# 예시: project/environments/develop/ap-northeast-2/shared/vpc/main.tf
module "vpc" {
  source = "../../../../../../modules/vpc/1.0.0"
}
```

> `project-b/environments/.../vpc/main.tf`에서도 동일하게 `../../../../../../modules/vpc/1.0.0`이다.

---

## 신규 리소스 추가 절차

1. `modules/{resource}/1.0.0/` 에 재사용 모듈 작성 (variables, main, outputs) — 신규 모듈은 항상 버전 디렉토리부터 시작
2. `project/environments/{env}/{region}/{service}/{resource}/` 디렉토리 생성
3. 아래 파일 작성:

| 파일 | 역할 |
|------|------|
| `backend.tf` | S3 backend, key 패턴 준수 |
| `providers.tf` | Provider `~> X.Y` 버전 제약 + `assume_role` 포함 |
| `locals.tf` | 환경별 설정값 집중 관리 |
| `data.tf` | 동적 데이터 소스 (AZ, region, caller identity 등) |
| `main.tf` | `modules/{resource}` 호출 (6단계 상대경로) |
| `outputs.tf` | 다른 root module이 참조할 값 노출 |

4. `terraform init && terraform plan && terraform apply`

---

## 신규 프로젝트 추가 절차

최상위에 `project-b/environments/` 디렉토리를 추가한다. `modules/`는 루트에 공용으로 존재하므로 신규 생성 불필요.

```bash
mkdir -p project-b/environments/develop/ap-northeast-2/shared/vpc
```

S3 key prefix는 `project-b/`로 시작하도록 `backend.tf`를 작성한다.
