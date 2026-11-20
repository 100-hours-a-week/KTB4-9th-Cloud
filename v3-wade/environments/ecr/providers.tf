provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "cosmos"
      Version   = "v3-wade"
      ManagedBy = "Terraform"
    }
  }
}
