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
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록"
  value       = module.vpc.private_subnet_ids
}

output "database_subnet_ids" {
  description = "데이터베이스 서브넷 ID 목록"
  value       = module.vpc.database_subnet_ids
}

output "tgw_subnet_ids" {
  description = "Transit Gateway 서브넷 ID 목록"
  value       = module.vpc.tgw_subnet_ids
}

output "nat_public_ips" {
  description = "NAT Gateway 퍼블릭 IP 목록"
  value       = module.vpc.nat_public_ips
}
