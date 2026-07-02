# K8s 운영 팁 (Operator Tips)

이 문서는 `kubectl` 운영 중 유용했던 명령어와 노하우를 주제별로 누적 기록하는
참고 자료다. 설계 문서(`docs/addon-strategy.md` 등)와 달리 "왜 이렇게 설계했는가"가
아니라 "운영 중 이 상황에서 이 명령어/도구가 유용했다"를 기록한다. 특정 로컬
환경(OS, 백신 등)에 종속된 설치·트러블슈팅 내용은 이 문서의 범위가 아니다.

새 팁을 추가할 때는 아래 형식을 따른다: 상황(언제 쓰는지) → 명령어 → 짧은 설명.

---

## RBAC 확인

### 특정 주체(User/ServiceAccount)가 뭘 할 수 있는지 바로 확인 — `kubectl auth can-i`

설치 없이 kubectl 자체 내장 명령으로 바로 된다. 가장 간단한 1차 확인 수단.

```bash
kubectl auth can-i --list --as=system:serviceaccount:<namespace>:<sa-name>
```

### 특정 주체가 어떤 Role/ClusterRole에 바인딩됐는지 — `kubectl rbac-tool lookup`

바인딩 이름까지만 보여준다 ("누구랑 묶여있나"). krew 플러그인 `rbac-tool`(alcideio) 제공.

```bash
kubectl rbac-tool lookup <subject-name>
```

### 바인딩된 Role의 실제 권한 규칙(verb/resource/apiGroup)까지 전개 — `kubectl rbac-tool policy-rules`

"그 Role이 실제로 뭘 허용하는데"까지 한 번에 표로 보여준다. `-e`는 subject 이름
정규식 필터. `describe clusterrole`을 직접 읽는 것보다 훨씬 보기 편하다.

```bash
kubectl rbac-tool policy-rules -e '<subject-name-regex>'
```

예: `verb=*, apiGroup=*, kind=*`가 뜨면 사실상 cluster-admin과 동급 — 과다 권한
여부를 한눈에 파악할 수 있다.

### 특정 동작(verb+resource)을 할 수 있는 모든 주체 역조회 — `kubectl who-can`

"누가 이걸 할 수 있냐"는 반대 방향 질문에 쓴다. krew 플러그인 `who-can`(aquasecurity) 제공.

```bash
kubectl who-can <verb> <resource> [-n <namespace>]
# 예: kubectl who-can delete secrets -n argocd
```

### 주체별 전체 리소스 접근 매트릭스 시각화 — `kubectl access-matrix`

리소스 종류(행) × verb(열) 표로 한눈에 파악하고 싶을 때. krew 플러그인 이름은
`access-matrix`이지만 프로젝트명은 rakkess — 검색 시 이름이 달라 헷갈리기 쉽다.

```bash
kubectl access-matrix --sa <namespace>:<sa-name>
kubectl access-matrix for pods --sa <namespace>:<sa-name>   # 특정 리소스만 좁혀보기
```

> ArgoCD `application-controller`처럼 어떤 매니페스트든 sync해야 하는 컨트롤러는
> 설계상 `ClusterRole`에 `apiGroups:["*"], resources:["*"], verbs:["*"]`를 요구한다
> (`modules/eks-addons/1.0.0/CLAUDE.md`의 "ArgoCD 설치" 섹션 참조). 위 명령들로
> 실제로 이렇게 설정돼 있는지 검증할 수 있다.

---

## kubectl 플러그인 관리 — krew

`kubectl` 자체에 없는 기능(RBAC 조회 등)은 `krew`로 설치하는 플러그인이 표준
확장 경로다. 자주 쓰는 플러그인:

| 플러그인 (krew 이름) | 용도 |
|---|---|
| `who-can` | 특정 verb+resource를 할 수 있는 주체 역조회 |
| `access-matrix` (rakkess 프로젝트) | 주체별 리소스×verb 접근 매트릭스 시각화 |
| `rbac-tool` (alcideio) | `lookup`(바인딩 조회), `policy-rules`(실제 권한 규칙 전개) |

> `rbac-lookup`(Fairwinds)은 기능은 유사하지만 플랫폼에 따라 미지원일 수 있다 —
> 설치 전 `kubectl krew search`로 가용 여부를 먼저 확인한다.
