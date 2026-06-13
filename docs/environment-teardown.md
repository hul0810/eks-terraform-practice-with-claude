# 환경 전체 삭제(teardown) 절차

## 배경

이 프로젝트는 실습 목적이 있어 비용 절감을 위해 develop 환경의
eks-addons → eks를 통째로 삭제하는 경우가 있다. VPC는 NAT Gateway를
제외하면 자체 비용이 발생하지 않으므로 이 문서의 삭제 대상에서 제외한다
(NAT Gateway 등 비용 발생 리소스는 별도로 직접 정리한다). production은
운영 환경이므로 클러스터 전체 삭제를 전제하지 않는다 — 이 문서는 develop
환경 기준이다.

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

## Route53 레코드 잔존 주의

ExternalDNS가 생성한 Route53 A 레코드(예: `argo-develop.pyhtest.com`)는
ALB 삭제와 별개로 남는다. ALB가 사라진 뒤에도 레코드가 남으면 존재하지
않는 ALB를 가리키는 dangling 레코드가 되므로 함께 확인·정리한다.

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id Z0651638YFNLNW79M27P \
  --query "ResourceRecordSets[?Name=='argo-develop.pyhtest.com.']"
```
