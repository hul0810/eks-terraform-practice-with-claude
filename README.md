# Terraform 기반 EKS 멀티 클러스터 인프라

AWS 2개 계정 위에 EKS 클러스터 3개를 Terraform으로 구축하고, 애드온·워크로드는 Hub-Spoke ArgoCD로 중앙 배포하는 개인 실습 인프라다.

- **목적**: **실무 EKS 숙련도 향상** — 실무에 바로 투입될 수 있는 수준으로 개념을 잡고 숙련도를 올리는 것
- **계정**: `monitoring`(공유 서비스) / `workload`(dev·prd), IAM Identity Center(SSO) 인증
- **클러스터**: monitoring(Hub) / develop / production
- **연계 저장소**: [devops-manifest](https://github.com/hul0810/eks-practice-devops-manifest)(GitOps 매니페스트) · [application](https://github.com/hul0810/eks-practice-application-with-claude)(MSA 앱)

---

## 아키텍처

```
┌─ monitoring 계정 ────────────────┐   ┌─ workload 계정 ─────────────────┐
│  ArgoCD (Hub) ───────────────────────▶ develop / production (spoke)   │
│  LGTM (Mimir·Loki·Tempo·Grafana) │   │  Karpenter 노드 (Spot 우선)      │
│  OTel Gateway ◀── VPC Peering ─────── OTel Agent (DaemonSet)          │
└──────────────────────────────────┘   └─────────────────────────────────┘
```

**관리 주체 경계**

- Terraform — AWS 리소스까지 (VPC·EKS·IAM·S3·ECR·SQS)
- ArgoCD — 클러스터 안까지 (애드온·앱·Karpenter NodePool)
- 둘을 잇는 다리 — Terraform이 IAM Role ARN을 ArgoCD `cluster` Secret annotation에 기록하면, ApplicationSet이 읽어 Helm values에 주입 (GitOps Bridge)
- 결과 — Terraform은 매니페스트를 모르고, ArgoCD는 IAM을 만들지 않는다

---

## 1. 확장성·관리 효율

**디렉토리 = 변경 반경(blast radius)**

- `{project}/environments/{env}/{region}/{service}/{resource}/` — 각 디렉토리가 독립 root module
- 리소스 타입마다 state를 격리해, 애드온 변경이 VPC state를 건드리지 않는다
- state key가 디렉토리 경로와 1:1 대응이라 규칙만 알면 위치를 역산할 수 있다

**클러스터를 하나 더 늘릴 때**

- 늘어나는 것 — root module 3종(`vpc`/`eks`/`eks-addons`)의 `locals.tf` 값, ArgoCD `cluster` Secret 1개
- 늘어나지 않는 것 — 모듈 코드(3클러스터가 동일 모듈 공유), 애드온 배포(등록 즉시 자동 생성·sync)

**Hub-Spoke를 고른 이유**

- 운영 표면 축소 — ArgoCD를 클러스터마다 운영하지 않고 Hub 1곳에서 업그레이드·RBAC 관리
- 버전 드리프트 차단 — 동일 ApplicationSet이 전 클러스터에 같은 차트를 배포
- 공격 표면 집중 — spoke에는 ArgoCD가 없다
- 계정 간 연결은 TGW 대신 VPC Peering — 연결 2개 규모에서 어태치먼트 비용을 정당화할 수 없었다

---

## 2. 코드 가독성·효율성

**의사결정 절차를 먼저 고정했다**

> ① 가장 단순한 방법에서 출발 → ② 단, 확장성·가독성·효율성·장기 유지비용 중 하나라도 해치면 → ③ 처음부터 올바른 구조로 → ④ 리팩토링이 이득이면 이번 변경에 포함

**일관 적용한 규칙**

| 영역 | 규칙 |
|---|---|
| 설정값 | root는 `locals.tf` 집중 관리(`tfvars` 미사용), 모듈은 `variable` 인터페이스 |
| 주소 안정성 | 반복 리소스는 `for_each`, `count`는 on/off 토글만, 인라인 SG 블록 금지 |
| 버전 고정 | 공식 모듈 `~> X.Y.Z` / provider `~> X.Y` / 애드온 버전 명시(`most_recent` 금지) |
| 모듈 버전 | `modules/{name}/{version}/` — 파괴적 변경은 새 버전 디렉토리로 격리 |
| 문서 | `README.md`는 terraform-docs 자동 생성(WHAT), `CLAUDE.md`는 수기(WHY) |
| 주석 | WHY만. WHAT 설명·변경 이력 서술 금지 |

**태그 거버넌스 3계층**

- Organizations Tag Policy — 허용값 정의 (값 위반은 못 막는다)
- `tag_policy_compliance` — plan 시 태그 **키 부재** 차단
- `precondition` — plan 시 태그 **값 위반** 차단, 허용값은 위 정책의 remote state에서 조회
- 허용값 추가는 한 곳만 고치면 전 root module에 반영된다

---

## 3. EKS 인프라 구성

| 판단 축 | 기준 |
|---|---|
| 애드온 분류 | **인프라 레벨**(클러스터·노드 그룹과 lifecycle 동일) → `eks` root에서 클러스터와 함께 / **애플리케이션 레벨**(구축 후 독립 운영) → `eks-addons` 별도 root |
| 설치 방식 | 인프라 레벨은 AWS 관리형 `aws_eks_addon`, 애플리케이션 레벨은 Helm(values 커스터마이징 필요) |
| 배포 순서 | `before_compute` — CNI는 노드 조인 전, CoreDNS는 노드 이후(먼저 깔면 데드락) |
| IAM 인증 | Pod Identity 우선, IRSA는 미지원 도구를 쓸 때만 예외 |
| GitOps 편입 | "ArgoCD 부트스트랩에 필요한가?" 하나로 판단 — ArgoCD 자신·repo-creds만 Terraform |

**오토스케일러 이원화 (Karpenter + Cluster Autoscaler)**

- 둘 다 Pending Pod로 동작하므로 대상이 겹치면 노드가 이중 프로비저닝된다
- 그래서 3계층으로 분리 — ① 시스템 노드 taint ② 시스템 애드온에 `role=system` nodeAffinity ③ Karpenter 자기 배치 제외
- **toleration은 허가지 강제가 아니다** — toleration만 넣은 ArgoCD 파드가 Karpenter 노드로 새어나간 실사례가 있어 "toleration + nodeAffinity 세트"로 못 박았다

**그 외 결정**

- 네트워크 — 4종 서브넷 분리, 노드는 private 전용, prd는 EKS endpoint private only
- SGP — `strict`가 아닌 `standard` 모드. `strict`는 링크로컬 경로가 사라져 Pod Identity가 아예 동작하지 않는다
- Observability — OTel Agent → Peering → Gateway → LGTM 중앙 수집
- 시크릿 — External Secrets Operator + SSM Parameter Store
- CI/CD — GitHub Actions OIDC로 ECR push(장기 키 제거) → Image Updater·Argo Rollouts
- 비용 — Spot 우선·consolidation·gp3를 기본값으로. 의도적으로 실무 기준에서 이탈한 항목은 **예외 목록에 복원 방법과 함께 기록**해 "모르고 빠뜨린 것"과 구분했다

---

## 4. LLM 가드레일

이 저장소의 코드는 상당 부분 LLM(Claude Code)과 함께 작성했다. 빠른 대신 세 가지 리스크가 생긴다 — 근거 없는 값 채움, 되돌리기 힘든 `apply`, 규칙 표류. 각각에 대응하는 4계층을 저장소 안에 넣었다.

- **① 규칙의 코드화** — `CLAUDE.md` + `docs/` 원칙 문서 + 모듈별 `CLAUDE.md`. 판단 기준을 사람 머리가 아니라 저장소에 둔다
- **② 근거 강제** — MCP(AWS 공식 문서·Terraform Registry)를 1차 조회 수단으로 고정, 확인분과 추론분을 구분 표기, 근거를 못 찾으면 추정 대신 "확인 필요"로 남긴다
- **③ 역할 분리 리뷰** — 6개 전문 에이전트를 정의하고 `.tf` 변경 시 4단계 순차 리뷰(코드 품질 → 보안 → 아키텍처 → 비용) 자동 실행
- **④ 하드 차단** — PreToolUse 훅이 production `terraform apply`를 차단. teardown 실습용 1회성 우회 마커만 허용해 실행 기록에 남긴다

**반복 작업의 스킬화**

- 실습 환경은 비용 때문에 필요할 때 올리고 끝나면 내린다 → `/env-provision`, `/env-teardown`으로 절차화
- `terraform destroy`로 안 지워지는 잔여물(ALB·Route53 레코드·고아 EBS·잔여 ENI)까지 절차에 포함
- 실패 패턴을 겪을 때마다 스킬 문서에 누적한다

---

## 더 깊이 보기

| 문서 | 내용 |
|------|------|
| [`TODO_LIST.md`](TODO_LIST.md) | Phase 1~9 전체 진행 내역과 남은 항목 |
| [`docs/terraform-principles.md`](docs/terraform-principles.md) | 엔지니어링 철학·근거 기반 원칙·버전 관리·비용 기본값 |
| [`docs/project-structure.md`](docs/project-structure.md) | 디렉토리 계층·state 격리·cross-layer 참조 |
| [`docs/addon-strategy.md`](docs/addon-strategy.md) | 애드온 분류·설치 방식·IAM 전략·오토스케일러 |
| [`docs/gitops-principles.md`](docs/gitops-principles.md) | GitOps 4원칙 적용 기준·부트스트랩 예외·알려진 갭 |
| [`docs/tag-governance.md`](docs/tag-governance.md) | 태그 3계층 거버넌스와 각 계층의 한계 |
| [`docs/network-design.md`](docs/network-design.md) | 계정 구조·VPC Peering·라우팅 설계 |
| [`docs/security-groups-for-pods.md`](docs/security-groups-for-pods.md) | SGP 동작 구조·모드 선택 근거 |
| [`docs/environment-teardown.md`](docs/environment-teardown.md) | 환경 삭제 순서와 수동 정리 항목 |
| [`docs/k8s-operator-tips.md`](docs/k8s-operator-tips.md) | 운영 중 축적한 트러블슈팅 기록 |

---

## 참고

일회성 구축물이 아니라 **EKS 숙련도 향상을 위해 계속 사용할 실습 환경**이다. 비용 때문에 필요할 때 올리고 끝나면 내리는 사이클로 운용하며, 새로 배우는 주제를 같은 설계 원칙에 얹어 계속 확장한다.
