# GitOps 원칙 정책

이 문서는 이 프로젝트가 GitOps Bridge 패턴(Phase 5~6)을 도입하면서 준수해야 할 원칙을
정책으로 명문화한다. "무엇을 왜 하는가"에 대한 서사·경위는 `temp/gitops-bridge-overview.md`에
이미 정리되어 있으므로 이 문서는 그 내용을 반복하지 않고, **앞으로의 변경이 지켜야 할 기준**만
간결하게 규정한다.

---

## 1. 근거 — OpenGitOps 4원칙

[OpenGitOps](https://opengitops.dev/)(CNCF App Delivery SIG)가 정의하는 GitOps 4원칙을
이 프로젝트의 공식 기준으로 채택한다.

| 원칙 | 정의 |
|------|------|
| 선언적(Declarative) | 시스템의 원하는 상태(desired state)를 명령형 절차가 아니라 선언적 구성으로 표현한다 |
| 버전관리·불변(Versioned/Immutable) | 원하는 상태는 버전 관리되며, 변경 불가능하고 전체 버전 이력을 유지하는 저장소(Git)에 보관한다 |
| 자동으로 Pull됨(Pulled Automatically) | 소프트웨어 에이전트(ArgoCD)가 저장소에서 원하는 상태를 자동으로 가져온다 — 사람이 push로 반영하지 않는다 |
| 지속적으로 조정됨(Continuously Reconciled) | 에이전트가 실제 상태를 지속적으로 관찰하고, 선언된 상태와의 편차를 자동으로 교정한다 |

---

## 2. 이 프로젝트에서의 적용 기준

아래 표는 이 프로젝트의 실제 구성 요소가 각 원칙을 어떻게 충족하는지, 그리고 새 변경을 검토할
때 확인해야 할 기준을 정의한다.

| 원칙 | 충족 수단 | 새 변경 시 확인 기준 |
|------|-----------|---------------------|
| 선언적 | `devops-manifest` 저장소의 Helm values / K8s manifest / ApplicationSet YAML | 새 addon·워크로드를 추가할 때 명령형 스크립트(`kubectl apply` 1회성 실행 등)로 상태를 만들지 않는다 — 반드시 선언적 파일로 저장소에 반영한다 |
| 버전관리·불변 | `eks-practice-devops-manifest` GitHub 저장소, PR 기반 변경 | 클러스터에 반영되는 모든 K8s 리소스 정의는 Git 커밋 이력으로 추적 가능해야 한다. 클러스터에 직접 `kubectl edit`로 임시 수정한 상태를 "정상"으로 방치하지 않는다 |
| 자동으로 Pull됨 | ArgoCD가 `argocd/applicationsets/`를 `root-app-addons.yaml`/`root-app-workload.yaml`(App of Apps 2개 분리, `directory.recurse: true`)로 자동 감시 | 새 addon Application/ApplicationSet은 이 감시 경로(`argocd/applicationsets/eks-addons` 또는 `/workload`) 안에 위치해야 자동 등록된다. 경로 밖에 두면 사람이 수동으로 `argocd app create`를 해야 하므로 이 원칙을 벗어난다 |
| 지속적으로 조정됨 | ArgoCD `syncPolicy.automated`(`Auto-Prune`) | addon Application 전체가 `syncPolicy: Automated(Prune)`로 전환됐다(devops-manifest, 확인일 2026-07-21 — `argocd app list --core`의 SYNCPOLICY 컬럼으로 실측). Git에 반영되면 별도 수동 sync 없이 자동 반영·자동 정리(prune)된다 — 아래 4절의 과거 갭은 해소됨 |

---

## 3. 이 프로젝트의 구조적 예외 — 부트스트랩 순환 의존성

4원칙은 **ArgoCD가 이미 그 리소스를 sync할 수 있는 상태**를 전제로 한다. ArgoCD 자신을
설치하거나 ArgoCD가 Git 저장소에 접근하기 위해 필요한 리소스는 이 전제 자체가 성립하지
않으므로, 4원칙 적용 대상에서 제외되는 것이 아니라 **애초에 GitOps 루프 진입 이전 단계**다.

이 판단 기준과 대상 리소스는 `docs/addon-strategy.md`의 "GitOps 관리 경계" 절이 이미
표로 정의하고 있다 — 이 문서는 그 표를 재정의하지 않고 참조한다:

- ArgoCD 자체 설치(Helm)
- ArgoCD repo-creds(Git 인증정보)
- root-app-addons 부트스트랩 ApplicationSet(devops-manifest의 repoURL·path·revision을
  가리키는 포인터, `monitoring/.../eks-addons/bootstrap/root-app-addons.yaml`) — ArgoCD가
  뜬 직후 devops-manifest를 처음 가리켜줄 대상이 없으면 GitOps 루프 자체가 시작되지
  않는다는 점에서 ArgoCD 자체 설치와 같은 카테고리다. 실제 addon 콘텐츠는 이 파일에
  없다(repoURL 등 좌표만 있음) — 그 콘텐츠는 devops-manifest가 100% 소유한다.

새 예외 대상을 추가로 판단해야 할 때도 별도 기준을 새로 만들지 않고, `docs/addon-strategy.md`의
판단 질문을 그대로 적용한다: **"ArgoCD 자신의 부트스트랩에 필요한 리소스인가, 아니면 ArgoCD가
이미 sync 가능한 상태에서 배포하는 리소스인가?"**

---

## 4. 알려진 원칙 미충족 갭

정책 문서인 만큼, 현재 코드가 4원칙을 완전히 충족하지 못하는 지점을 은폐하지 않고 명시한다.

| 갭 | 위반 원칙 | 현재 상태 | 추적 |
|----|-----------|-----------|------|
| Hub 자신(monitoring)의 cluster Secret이 SPOF | 자동으로 Pull됨 | 이 Secret 또는 `argocd.argoproj.io/secret-type: cluster` 라벨이 사라지면 `clusters` generator가 매칭 대상을 못 찾아 addon 전체가 **에러 없이** 배포 대상에서 사라진다 | `temp/gitops-bridge-overview.md` 9절 |
| Hub(monitoring) 자체의 관리 평면 가용성이 간헐적 | 자동으로 Pull됨 / 지속적으로 조정됨 | monitoring은 비용 절감을 위해 `/env-teardown`으로 상시 내려간다(이 프로젝트의 정상 운영 패턴) — Hub가 없는 동안은 spoke(dev/prod)에 대한 reconciliation 자체가 멈춘다. 다만 spoke에 이미 배포된 addon·워크로드는 각자의 K8s 컨트롤러로 계속 동작하므로(데이터 평면 무중단) 이 갭은 관리 평면에 한정된다 — aws-architect 리뷰 지적, 2026-07-21 | 없음(신규 기록) |

`syncPolicy.automated` 도입 여부(자동화 시 예기치 않은 배포 리스크 vs 수동 부담의
트레이드오프)는 `devops-manifest` 저장소 쪽 판단 사항이며, 이 저장소가 강제하지 않는다 —
`docs/addon-strategy.md`에 명시된 협업 경계(이 저장소가 devops-manifest를 직접 수정하지
않는다) 때문이다.

---

## 5. 신규 리소스 추가 시 체크리스트

새 addon 또는 워크로드를 GitOps로 편입할 때 아래 순서로 확인한다.

1. **선언적**: Helm values/manifest가 파일로 존재하는가 (즉흥 `kubectl apply` 금지)
2. **버전관리**: 그 파일이 `eks-practice-devops-manifest`에 커밋되는가
3. **자동 Pull**: `argocd/applicationsets/` 감시 경로 안에 위치하는가
4. **지속 조정**: `syncPolicy.automated`가 필요한 리소스인가, 아니면 Manual로 둘 근거가
   있는가 — 근거 없이 기본값(Manual)에 방치하지 않는다
5. **부트스트랩 예외 여부**: 위 3절의 판단 질문에 해당하면 GitOps 대상에서 제외하고
   `docs/addon-strategy.md` 표에 추가한다

---

## 관련 문서

- `docs/addon-strategy.md` — GitOps 관리 경계(부트스트랩 순환 의존성) 판단 기준 원본
- `temp/gitops-bridge-overview.md` — GitOps Bridge 도입 전체 경위·설계 논리 (세션 정리 대상,
  핵심 결론은 memory `project_gitops_bridge_metadata_gap.md`에도 보존됨)
- `TODO_LIST.md` Phase 5~6 — 타임라인·체크리스트
