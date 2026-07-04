# 환경 전체 삭제(teardown) 절차

> **자동화**: 아래 절차는 `/env-teardown <monitoring|develop|production>` 스킬로 자동화되어
> 있다 (`.claude/skills/env-teardown/SKILL.md`). Route53 레코드 잔존, Karpenter 노드 조기
> drain으로 인한 external-secrets 웹훅 교착까지 함께 처리한다. 생성은
> `/env-provision <monitoring|develop|production>`. 이 문서는 스킬이 수행하는 절차의 배경
> (WHY)을 설명하는 참고 자료로 유지한다.

## 배경

이 프로젝트는 실습 목적이 있어 비용 절감을 위해 environment의
eks-addons → eks를 통째로 삭제하는 경우가 있다. VPC는 NAT Gateway를
제외하면 자체 비용이 발생하지 않으므로 이 문서의 삭제 대상에서 제외한다
(NAT Gateway 등 비용 발생 리소스는 별도로 직접 정리한다). 아래 절차는
environment 이름만 바꾸면 monitoring/develop/production 어디에나 동일하게
적용된다.

---

## production teardown — 보호 원칙과 실습 예외

실무 기준으로 production은 **절대 보호해야 할 인프라**로 간주한다.
`project/environments/production/`에서 `terraform apply`는
`.claude/hooks/block-production-apply.sh` 훅이 기본적으로 하드 차단하며,
정상 배포는 `/git-commit` → PR → 팀 검토·승인 → 사용자가 터미널에서 직접
`apply`하는 절차를 거쳐야 한다 (`CLAUDE.md` "Production 배포 정책" 참조).

다만 이 프로젝트는 어디까지나 실습이므로, production도 다른 환경과 마찬가지로
**삭제(destroy)는 항상 가능해야 한다**. `terraform destroy`는 애초에 훅의
차단 대상이 아니므로(정규식이 `apply`만 감지) 별도 조치 없이 그대로
진행된다. 문제는 destroy 절차 중간에 `terraform apply`가 필요한 지점이
있다는 것이다 — 대표적으로 아래 **VPC NAT Gateway 비활성화** 단계.

### 임시 우회 마커로 apply 진행하기

이 단계에서는 명령 앞에 `ALLOW_PRODUCTION_TEARDOWN_APPLY=1` 마커를 붙여
실행한다. 훅이 이 마커를 command 문자열에서 감지하면 **그 명령 1회에 한해서만**
통과시킨다:

```bash
cd project/environments/production/ap-northeast-2/shared/vpc
ALLOW_PRODUCTION_TEARDOWN_APPLY=1 terraform apply -auto-approve
```

- 세션 전역 환경변수나 `.claude/settings.json` 수정이 아니라 **커맨드 단위** 마커다.
  트랜스크립트에 명령 그대로 남아 감사 가능하고, "우회를 끄는 걸 깜빡"할 위험이 없다.
- 마커 없이 실행하면 훅이 기존과 동일하게 차단하고 안내 메시지를 출력한다.
- **teardown(NAT Gateway 비활성화 등) 목적으로만 사용한다.** 일반 production 리소스
  변경·배포에는 이 마커를 붙이지 않는다 — production apply 보호 원칙 자체를 무력화하는
  용도가 아니라, 실습 편의를 위한 좁은 예외다.

`/env-teardown production` 스킬 실행 시 VPC NAT Gateway 비활성화 단계에서
이 마커를 자동으로 사용한다 (`.claude/skills/env-teardown/SKILL.md` 참조).

---

## 문제: LBC가 생성한 AWS 리소스의 Orphan화

`aws-load-balancer-controller`(LBC)는 Kubernetes Ingress 리소스를 보고
**ALB·Target Group·Listener·Security Group을 AWS API로 직접 생성**한다.
이 리소스들은 Terraform state에 존재하지 않는다 — Terraform이 관리하는 것은
Ingress까지이며(`helm_release.argocd`를 통해), ALB 등은 LBC가 비동기로
만들고 지우는 파생 리소스다.

`terraform destroy`로 eks-addons(LBC, ArgoCD 등 helm_release 포함)와
eks(클러스터)를 한 번에/연속으로 삭제하면, LBC가 Ingress 삭제를 감지하고
ALB를 정리(finalizer 처리)할 시간을 갖지 못한 채 자신도 종료되거나
클러스터 API 서버가 사라질 수 있다. 결과적으로 **ALB·Target Group·
Security Group이 AWS에 orphan 상태로 남아 비용이 계속 발생**한다.

---

## 권장 절차: eks-addons destroy 전 Ingress 정리 + 대기

### 1단계: Ingress 리소스 먼저 제거

```bash
kubectl get ingress -A
kubectl delete ingress <name> -n <namespace>   # 예: argocd-server -n argocd
```

### 2단계: LBC의 ALB 정리 완료 확인

```bash
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query "LoadBalancers[?contains(LoadBalancerName,'argocd')]"
```

빈 결과(`[]`)가 나올 때까지 대기한다 (보통 1~2분 내 완료).

### 3단계: 나머지 리소스 destroy (eks-addons → eks 순)

```bash
cd project/environments/develop/ap-northeast-2/shared/eks-addons && terraform destroy
cd ../eks && terraform destroy
```

> eks-addons에는 LBC 자신의 helm_release도 포함된다. 1~2단계로 ALB가
> 이미 정리된 뒤이므로, LBC가 함께 삭제되어도 orphan이 발생하지 않는다.
>
> VPC는 destroy하지 않는다 (자체 비용 없음). NAT Gateway를 활성화한 적이
> 있다면 비용 발생을 막기 위해 별도로 확인·정리한다.

---

## 이미 orphan이 발생한 경우 — 수동 정리

```bash
# 1. ALB 조회
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --query "LoadBalancers[].{Name:LoadBalancerName,ARN:LoadBalancerArn}"

# 2. 연결된 Target Group 조회
aws elbv2 describe-target-groups --region ap-northeast-2 \
  --query "TargetGroups[].{Name:TargetGroupName,ARN:TargetGroupArn}"

# 3. LBC가 생성한 ALB Security Group 조회 (보통 "k8s-" 접두사)
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters "Name=group-name,Values=k8s-*" \
  --query "SecurityGroups[].{Name:GroupName,Id:GroupId}"

# 4. 삭제 (의존성 역순: ALB → Target Group → Security Group)
aws elbv2 delete-load-balancer --load-balancer-arn <alb-arn>
aws elbv2 delete-target-group --target-group-arn <tg-arn>
aws ec2 delete-security-group --group-id <sg-id>
```

`delete-load-balancer`는 비동기이므로, Target Group/Security Group 삭제
전에 ALB가 실제로 사라졌는지(`describe-load-balancers`로 재확인) 확인한다.

---

## Karpenter 노드 강제 종료로 인한 VPC CNI ENI 잔존

`eks-addons` destroy 그래프의 `null_resource.karpenter_nodeclaims_drainer`는 Karpenter
Helm release/CRD가 사라지기 전에 NodeClaim을 먼저 강제 삭제해 destroy가 막히지 않도록 한다
(external-secrets 웹훅 교착 방지와 같은 이유 — 위 SKILL.md Step 6 참조). 그런데 NodeClaim을
강제로 지우면 Karpenter가 그 밑의 EC2 인스턴스를 **정상적인 cordon → drain 절차 없이**
빠르게 종료시킨다.

**왜 ENI가 남는가**: VPC CNI(aws-node)는 노드의 파드 밀도가 primary ENI의 IP 용량을 넘으면
secondary ENI를 추가로 붙인다. 이 secondary ENI는 `DeleteOnTermination=true`가 아니다 —
EC2가 인스턴스 launch 시 자동으로 붙이는 primary ENI만 이 플래그가 켜져 있고, secondary ENI는
CNI의 ipamd가 명시적으로 `DeleteNetworkInterface`를 호출해야 지워진다. 정상적인 노드
스케일다운이라면 종료 전에 ipamd가 이 정리를 마칠 시간이 있지만, 강제 종료 경로에서는
인스턴스가 먼저 사라져 정리 루틴이 끝까지 돌지 못한다. EC2는 인스턴스 종료 시 그 ENI를
detach만 하고 delete는 하지 않으므로 `available` 상태로 고아가 되어 남고, 여전히 node
security group을 참조하고 있어 `module.eks.module.eks.aws_security_group.node` 삭제가
`DependencyViolation`으로 막힌다 (2026-07-04 monitoring teardown에서 실제 발생).

**감지**: `eks` destroy가 `deleting Security Group ...: DependencyViolation: resource
... has a dependent object` 에러로 멈추면 아래로 확인한다.

```bash
aws ec2 describe-network-interfaces --region ap-northeast-2 --profile <profile> \
  --filters "Name=group-id,Values=<막힌 security-group-id>" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description}"
```

`Description`이 `aws-K8S-i-<instance-id>` 형태이고 `Status`가 `available`(= 이미 분리됨)이면
VPC CNI가 만든 secondary ENI가 정리되지 않고 남은 것이다. 인스턴스에서 이미 분리된 상태라
안전하게 직접 삭제할 수 있다.

```bash
aws ec2 delete-network-interface --region ap-northeast-2 --profile <profile> \
  --network-interface-id <eni-id>
```

삭제 후 `eks` destroy를 재시도하면 나머지(이번 사례에서는 security group 하나)만 이어서
정리된다.

---

## Route53 레코드 잔존 주의

ExternalDNS가 생성한 Route53 A 레코드(예: `argocd-develop.pyhtest.com`)는
ALB 삭제와 별개로 남는다. ALB가 사라진 뒤에도 레코드가 남으면 존재하지
않는 ALB를 가리키는 dangling 레코드가 되므로 함께 확인·정리한다.

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id Z0651638YFNLNW79M27P \
  --query "ResourceRecordSets[?Name=='argocd-develop.pyhtest.com.']"
```
