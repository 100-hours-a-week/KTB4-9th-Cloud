terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 기존 backend "s3" 대신 테라폼 클라우드 백엔드 사용
  cloud {
    organization = "cosmoscode"

    workspaces {
      name = "KTB4-9th-Cloud"
    }
  }
}

provider "aws" {
  region = var.aws_region
}