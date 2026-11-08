variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "public_access_cidrs" {
  description = "EKS API 퍼블릭 엔드포인트 접근 허용 CIDR"
  type        = list(string)

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "EKS API를 전체 인터넷에 공개할 수 없습니다."
  }
}

variable "edge_allowed_cidrs" {
  description = "서비스 도메인 접근 허용 CIDR"
  type        = list(string)
}

variable "seed_snapshot_identifier" {
  description = "scripts/seed.sh가 만든 RDS 시드 스냅샷"
  type        = string
}

variable "enable_edge" {
  type    = bool
  default = false
}
