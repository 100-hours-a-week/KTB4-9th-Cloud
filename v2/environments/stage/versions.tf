terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  cloud {
    organization = "cosmoscode"
    workspaces {
      name = "KTB4-9th-Cloud-v2-stage"
    }
  }
}
