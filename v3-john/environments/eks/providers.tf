provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cosmos"
      Version   = "v3-john"
      ManagedBy = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "cosmos"
      Version   = "v3-john"
      ManagedBy = "Terraform"
    }
  }
}
