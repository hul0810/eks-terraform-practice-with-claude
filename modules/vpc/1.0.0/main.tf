data "aws_region" "current" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6.1"

  name = var.vpc_name
  cidr = var.vpc_cidr

  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets
  intra_subnets    = var.tgw_subnets

  public_subnet_names   = [for az in var.azs : "${var.vpc_name}-public-${replace(az, "ap-northeast-", "apne-")}"]
  private_subnet_names  = [for az in var.azs : "${var.vpc_name}-private-${replace(az, "ap-northeast-", "apne-")}"]
  database_subnet_names = [for az in var.azs : "${var.vpc_name}-database-${replace(az, "ap-northeast-", "apne-")}"]
  intra_subnet_names    = [for az in var.azs : "${var.vpc_name}-tgw-${replace(az, "ap-northeast-", "apne-")}"]

  create_database_subnet_route_table = true

  private_route_table_tags = {
    Name = "${var.vpc_name}-private"
  }
  database_route_table_tags = {
    Name = "${var.vpc_name}-database"
  }
  intra_route_table_tags = {
    Name = "${var.vpc_name}-tgw"
  }

  # NAT Gateway
  # NAT GW 미사용 시 per-AZ RT는 의미 없으므로 단일 RT 강제
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.enable_nat_gateway ? var.single_nat_gateway : true
  one_nat_gateway_per_az = var.enable_nat_gateway ? !var.single_nat_gateway : false

  # AWS Load Balancer Controller가 서비스 어노테이션으로 서브넷을 자동 탐색하는 데 필요.
  # 이 태그가 없으면 Ingress 생성 시 "no matching subnets" 오류가 발생한다.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  enable_dns_hostnames = true
  enable_dns_support   = true

  # tags는 모든 서브넷·라우팅 테이블에 전파되므로 사용 금지. vpc_tags는 aws_vpc 리소스에만 적용.
  vpc_tags = var.additional_tags
}

# v6부터 모듈 인라인 지원 제거. Gateway 타입은 무료이며 NAT GW 데이터 비용 절감.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  # EKS 노드/Pod의 NAT GW 비용 절감이 목적.
  # database: Aurora S3 Export 미사용 시 불필요. 활성화 시 database_route_table_ids 추가.
  # tgw(intra): AWS 공식 제약 - TGW 경유 트래픽은 Gateway Endpoint 사용 불가.
  # public: ALB/NAT GW는 S3 직접 호출 주체가 아님. aws:SourceIp 정책 부작용 위험.
  route_table_ids = module.vpc.private_route_table_ids

  # module.vpc 내 route table의 create/destroy 완료 후 endpoint가 수정되도록 보장
  depends_on = [module.vpc]

  tags = var.additional_tags
}

resource "terraform_data" "validate_subnet_counts" {
  lifecycle {
    precondition {
      condition     = length(var.public_subnets) == 0 || length(var.public_subnets) == length(var.azs)
      error_message = "public_subnets(${length(var.public_subnets)}) != azs(${length(var.azs)}). 서브넷 수는 AZ 수와 일치해야 합니다."
    }
    precondition {
      condition     = length(var.private_subnets) == 0 || length(var.private_subnets) == length(var.azs)
      error_message = "private_subnets(${length(var.private_subnets)}) != azs(${length(var.azs)}). 서브넷 수는 AZ 수와 일치해야 합니다."
    }
    precondition {
      condition     = length(var.database_subnets) == 0 || length(var.database_subnets) == length(var.azs)
      error_message = "database_subnets(${length(var.database_subnets)}) != azs(${length(var.azs)}). 서브넷 수는 AZ 수와 일치해야 합니다."
    }
    precondition {
      condition     = length(var.tgw_subnets) == 0 || length(var.tgw_subnets) == length(var.azs)
      error_message = "tgw_subnets(${length(var.tgw_subnets)}) != azs(${length(var.azs)}). 서브넷 수는 AZ 수와 일치해야 합니다."
    }
  }
}
