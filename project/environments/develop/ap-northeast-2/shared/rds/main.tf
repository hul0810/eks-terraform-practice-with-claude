# 태그 값 유효성 검사: Organizations 정책의 허용값을 remote state에서 읽어 검증한다.
# 허용값 변경은 global/tag-policy/main.tf만 수정하면 된다.
resource "terraform_data" "validate_tags" {
  lifecycle {
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_environments, local.common_tags.environment)
      error_message = "environment 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_environments)}. 현재 값: '${local.common_tags.environment}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_managed_by, local.common_tags.managed_by)
      error_message = "managed_by 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_managed_by)}. 현재 값: '${local.common_tags.managed_by}'"
    }
    precondition {
      condition     = contains(data.terraform_remote_state.tag_policy.outputs.allowed_projects, local.common_tags.project)
      error_message = "project 태그 허용값: ${join(", ", data.terraform_remote_state.tag_policy.outputs.allowed_projects)}. 현재 값: '${local.common_tags.project}'"
    }
  }
}

################################################################################
# 서브넷 그룹
#
# VPC 모듈이 만든 데이터베이스 전용 서브넷(라우팅 테이블에 NAT/IGW 경로 없음)에 배치한다.
# RDS는 서로 다른 AZ의 서브넷을 최소 2개 요구하며, Single-AZ 구성이어도 이 제약은 동일하다.
################################################################################

resource "aws_db_subnet_group" "this" {
  name        = local.rds.identifier
  description = "Database subnets for ${local.rds.identifier}"
  subnet_ids  = local.database_subnet_ids

  tags = {
    Name = local.rds.identifier
  }
}

################################################################################
# 보안 그룹 — 이 프로젝트에서 SGP가 실제로 통제하는 지점
#
# inbound에 노드 SG가 아니라 Pod SG만 등록하는 것이 핵심이다. 노드 SG를 등록하면 그 노드의
# 모든 Pod가 통과해버려 SGP를 도입한 의미가 사라진다. Pod SG를 단 Pod는 자기 브랜치 ENI로
# 나오므로 RDS 입장에서 출발지 SG가 다르게 보이고, 같은 노드의 다른 Pod는 매칭되지 않는다.
#
# egress 규칙은 두지 않는다 — RDS는 연결을 먼저 걸지 않는다. aws_security_group 리소스는
# 인라인 egress를 선언하지 않으면 AWS 기본 all-allow 규칙을 제거한다.
################################################################################

resource "aws_security_group" "rds" {
  # name이 아니라 name_prefix를 쓴다. SG 이름은 VPC 내에서 유일해야 하는데, description처럼
  # Update API가 없는 속성을 바꾸면 SG가 ForceNew로 재생성된다 — 이때 create_before_destroy는
  # 기존 SG가 살아있는 상태에서 신규를 먼저 만들려 하므로 이름이 고정이면 InvalidGroup.Duplicate로
  # apply가 통째로 실패한다. 참조는 ID 기반이고, 사람이 식별하는 값은 Name 태그가 담당한다.
  name_prefix = "${local.rds.identifier}-rds-"
  description = "RDS access restricted to pods carrying the SGP pod security group"
  vpc_id      = local.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.rds.identifier}-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_pod_sg" {
  security_group_id = aws_security_group.rds.id
  description       = "PostgreSQL from SGP-enabled pods only"

  referenced_security_group_id = local.pod_rds_access_security_group_id
  from_port                    = local.rds.port
  to_port                      = local.rds.port
  ip_protocol                  = "tcp"

  tags = {
    Name = "${local.rds.identifier}-rds-from-pod-sg"
  }
}

################################################################################
# DB 인스턴스
################################################################################

resource "aws_db_instance" "this" {
  identifier = local.rds.identifier

  engine         = local.rds.engine
  engine_version = local.rds.engine_version
  instance_class = local.rds.instance_class

  storage_type          = local.rds.storage_type
  allocated_storage     = local.rds.allocated_storage
  max_allocated_storage = local.rds.max_allocated_storage
  storage_encrypted     = local.rds.storage_encrypted

  db_name  = local.rds.db_name
  username = local.rds.username
  password = data.aws_ssm_parameter.master_password.value
  port     = local.rds.port

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = local.rds.publicly_accessible
  multi_az               = local.rds.multi_az

  backup_retention_period      = local.rds.backup_retention_period
  monitoring_interval          = local.rds.monitoring_interval
  performance_insights_enabled = local.rds.performance_insights_enabled

  # 메이저 버전만 고정했으므로 마이너 업그레이드는 AWS에 위임한다(locals.tf 참조).
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  deletion_protection = local.rds.deletion_protection
  skip_final_snapshot = local.rds.skip_final_snapshot
  apply_immediately   = local.rds.apply_immediately

  lifecycle {
    ignore_changes = [
      # SSM 파라미터를 교체해 패스워드를 로테이션할 때, 그 값을 실제 RDS에 반영하는 것은
      # 별도 판단이 필요한 작업이다(연결 중인 워크로드의 시크릿 갱신과 순서를 맞춰야 함).
      # 여기서 자동 추종하면 SSM만 바꿔도 다음 apply에서 예고 없이 DB 패스워드가 바뀐다.
      password,
    ]
  }
}
