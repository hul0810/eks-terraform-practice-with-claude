variable "vpc_name" {
  description = "VPC 이름"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "유효한 IPv4 CIDR 블록을 입력해야 합니다. (예: 10.10.0.0/16)"
  }
}

variable "azs" {
  description = "사용할 가용 영역 목록"
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "고가용성을 위해 가용 영역은 최소 2개 이상 지정해야 합니다."
  }
}

variable "public_subnets" {
  description = "퍼블릭 서브넷 CIDR 목록 (ALB, NAT GW, Bastion용)"
  type        = list(string)
  default     = []
}

variable "private_subnets" {
  description = "프라이빗 서브넷 CIDR 목록 (EKS 노드, Pod IP용)"
  type        = list(string)
  default     = []
}

variable "database_subnets" {
  description = "데이터베이스 서브넷 CIDR 목록 (RDS, ElastiCache용)"
  type        = list(string)
  default     = []
}

variable "tgw_subnets" {
  description = "Transit Gateway 어태치먼트용 서브넷 CIDR 목록 (인터넷 라우팅 없음)"
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "NAT Gateway 생성 여부"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "true: 단일 NAT GW(비용 절감) / false: AZ당 1개(고가용성)"
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "VPC 및 VPC Endpoint 리소스에 추가할 태그 맵. 서브넷·라우팅 테이블에는 전파되지 않는다. providers.tf의 default_tags로 공통 태그(environment, managed_by)를 관리하므로, 이 변수는 리소스 식별에 필요한 추가 태그에만 사용한다."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Karpenter 서브넷 자동 탐색 태그(karpenter.sh/discovery)에 사용. null이면 태그를 추가하지 않는다. VPC가 EKS 클러스터와 연결되는 경우에만 지정한다."
  type        = string
  default     = null

  validation {
    # EKS 클러스터 이름 규칙: 1~100자, 영문·숫자·하이픈만 허용
    condition     = var.cluster_name == null || can(regex("^[a-zA-Z0-9-]{1,100}$", var.cluster_name))
    error_message = "cluster_name은 영문, 숫자, 하이픈(-)만 허용하며 1~100자여야 합니다."
  }
}
