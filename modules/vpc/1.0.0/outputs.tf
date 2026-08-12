output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR 블록"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록 (EKS 노드, Pod IP)"
  value       = module.vpc.private_subnets
}

output "database_subnet_group_name" {
  description = "데이터베이스 전용 서브넷 그룹 이름. 이 모듈이 database_subnets를 선언하면 공식 모듈이 서브넷 그룹까지 함께 만들므로, RDS를 쓰는 root는 자기 것을 새로 만들지 말고 이 값을 참조한다"
  value       = module.vpc.database_subnet_group_name
}

output "database_subnet_ids" {
  description = "데이터베이스 서브넷 ID 목록"
  value       = module.vpc.database_subnets
}

output "tgw_subnet_ids" {
  description = "Transit Gateway 어태치먼트용 서브넷 ID 목록"
  value       = module.vpc.intra_subnets
}

output "private_route_table_ids" {
  description = "프라이빗 서브넷 라우팅 테이블 ID 목록"
  value       = module.vpc.private_route_table_ids
}

output "database_route_table_ids" {
  description = "데이터베이스 서브넷 라우팅 테이블 ID 목록"
  value       = module.vpc.database_route_table_ids
}

output "tgw_route_table_ids" {
  description = "TGW 서브넷 라우팅 테이블 ID 목록 (TGW 도입 시 경로 추가용)"
  value       = module.vpc.intra_route_table_ids
}

output "nat_public_ips" {
  description = "NAT Gateway 퍼블릭 IP 목록"
  value       = module.vpc.nat_public_ips
}

output "public_route_table_ids" {
  description = "퍼블릭 서브넷 라우팅 테이블 ID 목록"
  value       = module.vpc.public_route_table_ids
}
