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
> (`modules/eks-addons/2.0.0/CLAUDE.md`의 "ArgoCD 설치" 섹션 참조 — ArgoCD는 monitoring
> Hub에만 있으므로 이 검증도 monitoring 클러스터에서 한다). 위 명령들로
> 실제로 이렇게 설정돼 있는지 검증할 수 있다.

---

## webhook을 쓰는 오퍼레이터/애드온 도입 시 점검 — 노드 SG 포트 대조

admission webhook을 갖는 컴포넌트(오퍼레이터, 인증서 발급기 등)를 새로 도입할 때는
**webhook이 실제로 리스닝하는 포트가 노드 SG에 열려 있는지**를 먼저 대조한다.

EKS 컨트롤 플레인은 AWS 관리 VPC에서 돌고 고객 VPC에는 크로스 계정 ENI만 꽂혀 있어
**ClusterIP를 라우팅하지 못한다**. 그래서 `ValidatingWebhookConfiguration`에 `port: 443`으로
적혀 있어도 API 서버는 Service를 Endpoints로 해석해 `<파드IP>:<targetPort>`로 직접 연결한다
— SG 평가 대상은 443이 아니라 **컨테이너 포트**다.

```bash
# 1) 실제로 필요한 포트 (Endpoints의 <파드IP>:<포트>)
kubectl get endpoints -n <namespace> <webhook-service>

# 2) 현재 열려 있는 포트
aws ec2 describe-security-group-rules --profile <profile> \
  --filters Name=group-id,Values=<node-sg> \
  --query 'SecurityGroupRules[?IsEgress==`false`].[FromPort,Description]' --output text | sort -n
```

**1의 포트가 2에 없으면 그게 다음 사고 후보다.** 업스트림
`node_security_group_enable_recommended_rules`가 열어주는 포트는 4443/6443/8443/9443/
10250/10251로 고정이라, 그 밖의 포트를 쓰는 컴포넌트는 반드시 직접 추가해야 한다
(`modules/eks/1.0.0`의 `node_security_group_additional_rules` 참조).

### 증상으로 역추적하기

이 문제는 증상이 원인에서 여러 단계 떨어져 있어 알아보기 어렵다. 아래 체인을 기억해둔다:

| 단계 | 관찰되는 것 |
|---|---|
| 1 | 오퍼레이터 파드가 `ContainerCreating`에서 안 넘어감 |
| 2 | `kubectl describe pod` → `MountVolume.SetUp failed for volume "cert": secret "..." not found` |
| 3 | 그 Secret은 `Certificate`가 만든다 → `kubectl get certificate -A`가 비어 있음 |
| 4 | ArgoCD sync 결과 → `Issuer`/`Certificate`만 `SyncFailed`, `failed calling webhook ... context deadline exceeded` |
| 5 | **실제 원인**: 노드 SG에 해당 webhook 포트 인바운드 없음 |

### 도달성 라이브 테스트

SG 반영 후 아래로 즉시 검증한다 — `--dry-run=server`는 etcd에 저장하지 않고 admission만
호출하므로 부작용이 없다.

```bash
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: {name: webhook-reachability-test, namespace: default}
spec: {selfSigned: {}}
EOF
```

`created (server dry run)`이 나오면 도달 성공, 타임아웃이면 SG를 다시 확인한다.

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

---

## IAM 인증 방식 변경이 파드에 반영되지 않을 때

Pod Identity / IRSA 관련 변경 후 파드가 여전히 옛 권한으로 동작하면, **무엇을 바꿨는지에
따라 재시작 필요 여부가 갈린다.**

| 변경 내용 | 파드 재시작 | 근거 |
|---|---|---|
| Pod Identity association의 **내용**(연결된 Role, 세션 정책) 변경 | 불필요 | Pod Identity Agent가 다음 크레덴셜 갱신 때 자동 반영 (AWS 공식 문서) |
| **인증 방식 자체** 전환 (IRSA ↔ Pod Identity) | **필요** | 파드에 주입되는 환경변수가 통째로 바뀌는데, 이미 떠 있는 파드에는 소급 적용되지 않음 (실측 확인) |

인증 방식 전환은 Terraform이 `helm_release`를 in-place update해도 파드가 자동 재시작되지
않는다. ServiceAccount annotation은 파드 템플릿이 아니라 별개 오브젝트라 롤아웃을
유발하지 않기 때문이다. 결과적으로 **IAM 신뢰 정책은 새 방식인데 파드 환경변수는 옛
방식인 불일치 상태**가 조용히 유지된다.

현재 파드가 어느 방식으로 인증 중인지 확인:

```bash
# IRSA면 AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE
# Pod Identity면 AWS_CONTAINER_CREDENTIALS_FULL_URI / AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
kubectl exec -n <ns> <pod> -- env | grep AWS_

# association 자체가 걸려 있는지는 AWS 쪽에서 확인
aws eks list-pod-identity-associations --cluster-name <cluster>
```

옛 방식 환경변수가 남아 있으면 파드를 강제 재생성한다.

```bash
kubectl delete pod <pod> -n <ns>
```
