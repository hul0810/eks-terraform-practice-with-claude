output "db_instance_identifier" {
  description = "RDS 인스턴스 식별자"
  value       = aws_db_instance.this.identifier
}

output "db_instance_address" {
  description = "RDS 엔드포인트 호스트명(포트 제외). SGP 검증 시 psql 접속 대상"
  value       = aws_db_instance.this.address
}

output "db_instance_endpoint" {
  description = "RDS 엔드포인트(host:port)"
  value       = aws_db_instance.this.endpoint
}

output "db_instance_port" {
  description = "RDS 포트"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "초기 생성되는 데이터베이스 이름"
  value       = aws_db_instance.this.db_name
}

output "db_username" {
  description = "마스터 사용자 이름. 패스워드는 SSM /eks-practice/develop/rds/master-password에 있다"
  value       = aws_db_instance.this.username
}

output "rds_security_group_id" {
  description = "RDS에 부착된 SG ID. inbound에는 Pod SG만 등록되어 있다"
  value       = aws_security_group.rds.id
}
