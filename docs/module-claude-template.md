# {모듈명} 모듈 설계 가이드

> 새 모듈 추가 시 이 파일을 복사하여 `modules/{name}/CLAUDE.md`로 저장한다.
> 공통 Terraform 원칙(`@docs/terraform-principles.md`)은 여기서 반복하지 않는다.
> 이 모듈에서만 적용되는 특이사항과 설계 결정만 기록한다.

---

## 핵심 설계 원칙

이 모듈에서 반드시 지켜야 할 설계 결정을 기록한다.
WHY 중심으로 작성한다 — "무엇"은 코드가 설명하므로 "왜 이렇게 결정했는가"를 남긴다.

예시:
- Public 서브넷에 NAT Gateway를 배치하는 이유: Private 서브넷의 아웃바운드 인터넷 트래픽 처리

---

## 리소스 명명 규칙

이 모듈에서 생성하는 리소스의 이름 패턴을 정의한다.

예시:
- 서브넷: `{vpc_name}-{type}-{az_abbr}` (예: `prod-vpc-private-apne2-az1`)
- AZ 약어: `ap-northeast-2a` → `apne2-az1`

---

## 중요 파라미터 결정 기준

어떤 값을 어떤 기준으로 선택하는지 기록한다.

예시:
- Private 서브넷 CIDR: /19 사용 (EKS 노드 및 Pod IP 여유 확보)
- Database 서브넷: 별도 라우팅 테이블 필수 (`create_database_subnet_route_table = true`)

---

## 알려진 제약사항 / 예외

특정 AZ 미지원 인스턴스, 서비스 한도, 특수 라우팅 등 예외 케이스를 기록한다.

예시:
- `ap-northeast-2c` AZ는 일부 인스턴스 타입 미지원 — 해당 리소스에서 개별 필터링
- S3 Gateway Endpoint는 Public 서브넷에 연결하지 않음 (Public은 IGW 통해 직접 접근)
