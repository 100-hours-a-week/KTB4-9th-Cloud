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
  description = "eks.cosmoscode.site 검증 기간 접근 허용 CIDR"
  type        = list(string)
}
