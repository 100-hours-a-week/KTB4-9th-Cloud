terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "cosmos-tfstate-us-west-2"
    key    = "v2/mlflow/terraform.tfstate"
    region = "us-west-2"
  }
}
