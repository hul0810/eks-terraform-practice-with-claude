################################################################################
# EKS 모듈 입력 변수
################################################################################

variable "cluster_name" {
  description = "EKS 클러스터 이름 (IAM Role, Security Group 등 연관 리소스의 Name에도 사용됨)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes 버전. AWS EKS가 지원하는 버전만 지정 가능 (예: \"1.32\")"
  type        = string

  validation {
    # 1.XX 형식 검증 — EKS 지원 버전 범위(1.25 이상)는 AWS 콘솔에서 별도 확인 필요
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version은 \"1.XX\" 형식이어야 합니다 (예: \"1.32\")."
  }
}

variable "vpc_id" {
  description = "EKS 클러스터 및 노드 Security Group을 생성할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "노드 그룹(Managed Node Group)을 배치할 서브넷 ID 목록. 멀티 AZ 고가용성을 위해 최소 2개 이상의 서브넷(다른 AZ) 필요"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids는 고가용성을 위해 최소 2개 이상이어야 합니다."
  }
}

variable "endpoint_public_access" {
  description = "EKS API 서버 퍼블릭 엔드포인트 활성화 여부. develop=true(로컬 kubectl 접근), production=false(VPN/Bastion 경유)"
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "EKS API 서버 퍼블릭 엔드포인트 허용 CIDR 목록. endpoint_public_access=true 시 반드시 IP를 제한해야 한다. 기본값 0.0.0.0/0은 인터넷 전체 노출이므로 환경별로 반드시 재정의할 것."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  description = "활성화할 컨트롤 플레인 로그 타입 목록. 빈 리스트이면 비활성화 (CloudWatch Logs 비용 절감). 가능한 값: api, audit, authenticator, controllerManager, scheduler"
  type        = list(string)
  default     = []
}

variable "system_node_instance_types" {
  description = "시스템 노드 그룹 EC2 인스턴스 타입 목록 (우선순위 순). Karpenter, CoreDNS, LBC 등 시스템 애드온이 실행되므로 최소 t3.medium 이상 권장"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_node_min_size" {
  description = "시스템 노드 그룹 최소 노드 수"
  type        = number
  default     = 1
}

variable "system_node_max_size" {
  description = "시스템 노드 그룹 최대 노드 수"
  type        = number
  default     = 3
}

variable "system_node_desired_size" {
  description = "시스템 노드 그룹 초기(희망) 노드 수"
  type        = number
  default     = 2
}

variable "system_node_ami_type" {
  description = "시스템 노드 그룹 AMI 타입. AL2023_x86_64_STANDARD = Amazon Linux 2023 x86_64 기본 이미지"
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "project" {
  description = "프로젝트 이름. 시스템 노드 그룹 이름 조합에 사용된다 ({project}-system-{environment}). cluster_name 대신 사용하는 이유: cluster_name은 project+environment를 이미 포함해 이름이 길어지면 IAM role name_prefix 38자 한도를 초과한다."
  type        = string
}

variable "environment" {
  description = "배포 환경 (develop / production). 시스템 노드 그룹 이름 접미사로 사용되어 AWS 콘솔에서 환경을 즉시 식별할 수 있게 한다."
  type        = string
}

variable "additional_tags" {
  description = "모든 리소스에 추가할 태그 맵. providers.tf의 default_tags로 공통 태그(environment, managed_by)를 관리하므로, 이 변수는 리소스 식별에 필요한 추가 태그에만 사용한다."
  type        = map(string)
  default     = {}
}

variable "node_security_group_additional_rules" {
  description = "node_sg에 추가할 보안 그룹 규칙 맵. node_security_group_enable_recommended_rules가 커버하지 못하는 규칙을 환경별로 주입한다. 업스트림 모듈의 node_security_group_additional_rules 스키마를 따른다."
  type        = any
  default     = {}
}

variable "node_security_group_tags" {
  description = "node SG에 추가할 태그 맵. Karpenter SG 탐색 태그(karpenter.sh/discovery) 등 node SG 전용 태그에만 사용한다. additional_tags는 default_tags로 관리되므로 이 변수는 node SG에만 적용이 필요한 태그에 한정한다. karpenter.sh/discovery 값은 EC2NodeClass securityGroupSelectorTerms 및 cluster_name과 반드시 일치해야 한다."
  type        = map(string)
  default     = {}
}

variable "upgrade_policy" {
  description = "클러스터 지원 정책. EXTENDED = 표준 지원 종료 후 Extended Support 자동 진입($0.60/hr 추가), STANDARD = 표준 지원 종료 후 다음 버전으로 자동 업그레이드. null이면 AWS 기본값(EXTENDED) 사용"
  type = object({
    support_type = optional(string, "EXTENDED")
  })
  default = null

  validation {
    condition     = var.upgrade_policy == null || contains(["EXTENDED", "STANDARD"], var.upgrade_policy.support_type)
    error_message = "upgrade_policy.support_type은 \"EXTENDED\" 또는 \"STANDARD\" 이어야 합니다."
  }
}

variable "zonal_shift_config" {
  description = "ARC Zonal Shift 활성화 여부. null이면 모듈 기본값(비활성화) 사용. 콘솔에서 값을 변경하면 Terraform 드리프트가 발생하므로 반드시 이 변수로 명시적으로 관리한다."
  type = object({
    enabled = optional(bool)
  })
  default = null
}

variable "addon_versions" {
  description = "Bootstrap 애드온 버전 맵. most_recent 사용 금지 — 명시적 버전 고정이 환경 간 일관성을 보장한다"
  type = object({
    vpc_cni                = string
    kube_proxy             = string
    coredns                = string
    eks_pod_identity_agent = string
    ebs_csi_driver         = string
  })
}

variable "coredns_configuration_values" {
  description = "CoreDNS EKS 관리형 애드온 configuration_values JSON 문자열. dev에서 replicaCount=1로 설정하여 시스템 노드 pod 슬롯을 절약한다. null이면 기본값(replicaCount=2) 사용"
  type        = string
  nullable    = true
  default     = null
}

variable "ebs_csi_configuration_values" {
  description = "EBS CSI Driver EKS 관리형 애드온 configuration_values JSON 문자열. dev에서 controller.replicaCount=1로 설정하여 시스템 노드 pod 슬롯을 절약한다. null이면 기본값(replicaCount=2) 사용"
  type        = string
  nullable    = true
  default     = null
}

variable "access_entries" {
  description = "EKS Access Entry 목록. IAM 엔티티(User/Role)에 Kubernetes 권한을 부여한다. principal_arn별로 policy_associations를 중첩 map으로 선언한다. 클러스터가 재생성되어도 terraform apply 한 번으로 접근 권한이 자동 복원된다."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    user_name         = optional(string)
    tags              = optional(map(string), {})
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        namespaces = optional(list(string))
        type       = string
      })
    })), {})
  }))
  default = {}
}
