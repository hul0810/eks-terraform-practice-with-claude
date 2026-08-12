locals {
  environment = "develop"
  project     = "eks-practice"

  # 리소스 이름 생성 전용 축약값. environment(태그용)와 분리한다.
  # 상세: docs/terraform-principles.md → 리소스 네이밍 규칙
  environment_short = "dev"
  name_suffix       = local.environment_short != "" ? "-${local.environment_short}" : ""

  # providers.tf default_tags의 단일 정의 지점. data source 참조 금지 (providers.tf 순환 의존 방지).
  common_tags = {
    environment = local.environment
    managed_by  = "terraform"
    project     = local.project
  }

  vpc_id              = data.terraform_remote_state.vpc.outputs.vpc_id
  database_subnet_ids = data.terraform_remote_state.vpc.outputs.database_subnet_ids

  # eks-addons/가 소유하는 Pod 전용 SG. 이 SG를 단 Pod만 아래 RDS에 접근할 수 있다
  # (eks-addons/pod-security-groups.tf 참조).
  pod_rds_access_security_group_id = data.terraform_remote_state.eks_addons.outputs.pod_rds_access_security_group_id

  rds = {
    # EKS 클러스터와 동일한 이름 규칙을 쓴다 — 이 RDS는 그 클러스터 워크로드 전용이라
    # 두 리소스를 같은 이름으로 묶어 소속을 드러낸다.
    identifier = "${local.project}${local.name_suffix}"

    # 메이저 버전만 고정한다. 전체 버전을 박으면 auto_minor_version_upgrade가 올린 마이너와
    # 코드가 어긋나 매 plan마다 diff가 뜬다. 메이저 업그레이드는 이 값을 바꿔야만 일어난다.
    #
    # db.t4g.micro + PostgreSQL 18 조합은 API로 확인했다 — 18.3/18.4가 orderable이며 18.4는
    # ap-northeast-2의 4개 AZ 전부에서 제공된다(2026-08-12 조회).
    # RDS User Guide의 burstable 클래스 지원표에는 db.t4g 행이 아직 17까지만 적혀 있어 문서와
    # API가 어긋나는데, 실제 생성 가능 여부는 API가 기준이다.
    #   aws rds describe-orderable-db-instance-options --engine postgres \
    #     --db-instance-class db.t4g.micro --region ap-northeast-2 --profile terraform-workload \
    #     --query 'OrderableDBInstanceOptions[].EngineVersion'
    engine         = "postgres"
    engine_version = "18"

    # db.t4g.micro(Graviton, 2 vCPU / 1 GiB): ap-northeast-2 $0.025/hr — 이 클래스가 최저가다
    # (2026-08-12 Pricing API 조회). 실습 대상이라 성능 요건이 없다.
    instance_class = "db.t4g.micro"

    # gp3 최소 크기. $0.131/GB-월 (2026-08-12 Pricing API 조회, Single-AZ).
    # 400GB 미만 gp3는 iops/throughput을 지정하지 않으면 기본 성능이 적용된다.
    storage_type          = "gp3"
    allocated_storage     = 20
    max_allocated_storage = 0 # 스토리지 오토스케일링 비활성 — 실습 중 의도치 않은 증설 방지

    db_name  = "practice"
    username = "dbadmin"
    port     = 5432

    # ── 비용 예외 항목 (루트 CLAUDE.md 참조) ──────────────────────────────────
    # 실습 대상 RDS이므로 가용성보다 비용을 우선한다.
    #   HA 복원 시: multi_az = true (비용 약 2배)
    multi_az = false

    # 자동 백업 비활성. 보존 기간이 0이면 PITR과 자동 스냅샷이 모두 꺼진다.
    # 실습 데이터라 복구 요건이 없고, 스냅샷 스토리지 비용도 발생하지 않는다.
    backup_retention_period = 0

    # Enhanced Monitoring(CloudWatch 지표 세분화)과 Performance Insights는 모두 추가 과금 대상이라 끈다.
    monitoring_interval          = 0
    performance_insights_enabled = false

    # ── teardown 대응 ─────────────────────────────────────────────────────────
    # 이 환경은 env-provision/env-teardown 사이클을 돈다. 삭제를 막는 설정을 두면
    # teardown이 사람 손을 타야 하므로 의도적으로 전부 해제한다 —
    # docs/terraform-principles.md의 prevent_destroy 권고가 적용되지 않는 예외다.
    deletion_protection = false
    skip_final_snapshot = true

    # 실습 환경이라 변경을 다음 유지보수 창까지 미룰 이유가 없다.
    apply_immediately = true

    # AWS 관리형 키(aws/rds)로 저장 데이터를 암호화한다. 무료이고 끄면 다시 켤 때
    # 인스턴스 재생성이 필요하므로 처음부터 켠다.
    storage_encrypted = true

    # private 서브넷 배치. SGP Pod는 브랜치 ENI로 VPC 내부 경로를 타므로 퍼블릭 노출이 필요 없다.
    publicly_accessible = false
  }
}
