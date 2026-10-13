provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "cosmos"
      Version     = "v2"
      Environment = "prod"
      ManagedBy   = "Terraform"
    }
  }
}
