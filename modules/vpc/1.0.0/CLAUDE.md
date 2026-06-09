# modules/vpc 설계 원칙

## 서브넷 명칭 패턴

`{vpc_name}-{type}-{az_abbr}` 형식. 리전 약어는 `replace(az, "ap-northeast-", "apne-")` 적용.

```hcl
# 예시: eks-practice-dev-public-apne-2a
[for az in var.azs : "${var.vpc_name}-{type}-${replace(az, "ap-northeast-", "apne-")}"]
```

## CIDR 설계

서브넷 타입별로 그룹화하여 AZ 수만큼 순서대로 배치한다.

| 타입     | CIDR 범위             | 크기 | 비고 |
|----------|-----------------------|------|------|
| Public   | `x.x.0~3.0/24`        | /24  | ALB, NAT GW |
| Database | `x.x.4~7.0/24`        | /24  | RDS, ElastiCache |
| TGW      | `x.x.8.0/28` ~        | /28  | 동일 /24 내 연속 배치 |
| Private  | `/19` 경계(32의 배수)  | /19  | EKS 노드, Pod |

## TGW 서브넷

`terraform-aws-modules/vpc`의 `intra_subnets` 타입을 활용한다.
인터넷/NAT 라우팅 없음, AWS 공식 권고 구성.

## Database 라우팅 테이블

`create_database_subnet_route_table = true` 를 항상 활성화한다.
미설정 시 `database_route_table_ids`가 비어 있어 S3 Gateway Endpoint 연결 불가.

## Karpenter 서브넷 자동 탐색 태그

Karpenter는 `karpenter.sh/discovery = {cluster_name}` 태그가 붙은 서브넷에만 노드를 프로비저닝한다.
이 태그는 `cluster_name` 변수가 제공된 경우에만 조건부로 추가한다.

```hcl
# null이면 태그 없음 — EKS와 무관한 VPC에서도 이 모듈을 재사용 가능하게 한다
private_subnet_tags = merge(
  { "kubernetes.io/role/internal-elb" = "1" },
  var.cluster_name != null ? { "karpenter.sh/discovery" = var.cluster_name } : {}
)
```

`karpenter.sh/discovery` 값은 EC2NodeClass의 `subnetSelectorTerms.tags` 값과 반드시 일치해야 한다.
불일치 시 Karpenter가 서브넷을 탐색하지 못해 노드 프로비저닝이 실패한다.

---

## S3 Gateway Endpoint 연결 대상

| 서브넷 타입 | 포함 여부 | 이유 |
|-------------|-----------|------|
| Private     | ✅        | EKS 노드/Pod S3 접근 (NAT GW 비용 절감) |
| Database    | 선택적    | Aurora S3 Export 사용 시에만 추가. 미사용 시 제외 |
| TGW (intra) | ❌        | AWS 공식 제약: TGW 경유 트래픽은 Gateway Endpoint 사용 불가 |
| Public      | ❌        | ALB/NAT GW는 S3 직접 호출 주체가 아님. `aws:SourceIp` 정책 부작용 위험 |
