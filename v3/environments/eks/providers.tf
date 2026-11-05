provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cosmos"
      Version   = "v3"
      ManagedBy = "Terraform"
    }
  }
}
