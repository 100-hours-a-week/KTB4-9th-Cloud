variable "aws_region" {
  description = "공유 인프라를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "aws_region은 ap-northeast-2여야 합니다."
  }
}

variable "project_name" {
  description = "공유 리소스 이름 접두사"
  type        = string
  default     = "cosmos-v2"
}

variable "domain_name" {
  description = "Public DNS domain used by the regional wildcard certificate"
  type        = string
  default     = "cosmoscode.site"

  validation {
    condition = (
      var.domain_name == trimspace(var.domain_name) &&
      !endswith(var.domain_name, ".") &&
      can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    )
    error_message = "domain_name must be a lowercase DNS name without whitespace or a trailing dot."
  }
}

variable "vpc_cidr" {
  description = "공유 VPC CIDR"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr은 유효한 IPv4 CIDR이어야 합니다."
  }
}

variable "availability_zones" {
  description = "공유 네트워크에서 사용할 두 가용 영역"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "availability_zones에는 서로 다른 두 가용 영역이 필요합니다."
  }
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR 두 개"
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "public_subnet_cidrs에는 유효한 IPv4 CIDR 두 개가 필요합니다."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR 두 개"
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2 && alltrue([for cidr in var.private_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "private_subnet_cidrs에는 유효한 IPv4 CIDR 두 개가 필요합니다."
  }
}

variable "data_subnet_cidrs" {
  description = "격리된 Data subnet CIDR 두 개"
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24"]

  validation {
    condition     = length(var.data_subnet_cidrs) == 2 && alltrue([for cidr in var.data_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "data_subnet_cidrs에는 유효한 IPv4 CIDR 두 개가 필요합니다."
  }
}

variable "ecr_repository_names" {
  description = "환경이 공유하는 ECR repository 서비스명"
  type        = set(string)
  default = [
    "spring",
    "fastapi",
    "judge",
  ]

  validation {
    condition     = var.ecr_repository_names == toset(["spring", "fastapi", "judge"])
    error_message = "ecr_repository_names에는 spring, fastapi, judge 세 서비스명이 필요합니다."
  }
}

variable "ecr_tagged_image_count" {
  description = "ECR별 보존할 tagged image 수"
  type        = number
  default     = 20

  validation {
    condition     = var.ecr_tagged_image_count > 0
    error_message = "ecr_tagged_image_count는 0보다 커야 합니다."
  }
}

variable "ecr_untagged_max_age_days" {
  description = "untagged image 최대 보존 일수"
  type        = number
  default     = 7

  validation {
    condition     = var.ecr_untagged_max_age_days > 0
    error_message = "ecr_untagged_max_age_days는 0보다 커야 합니다."
  }
}

