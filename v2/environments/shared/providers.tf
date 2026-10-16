provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "cosmos"
      Version   = "v2"
      Scope     = "shared"
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

