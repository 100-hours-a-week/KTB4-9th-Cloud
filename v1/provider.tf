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

# CloudFront ACM 인증서 발급 전용 (반드시 us-east-1 이어야 함)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}