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
