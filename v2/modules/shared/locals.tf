locals {
  common_tags = {
    Project   = "cosmos"
    Version   = "v2"
    Scope     = "shared"
    ManagedBy = "Terraform"
  }

  public_subnets = {
    for index, cidr in var.public_subnet_cidrs : tostring(index) => {
      availability_zone = var.availability_zones[index]
      cidr_block        = cidr
      index             = index
    }
  }

  private_subnets = {
    for index, cidr in var.private_subnet_cidrs : tostring(index) => {
      availability_zone = var.availability_zones[index]
      cidr_block        = cidr
      index             = index
    }
  }

  data_subnets = {
    for index, cidr in var.data_subnet_cidrs : tostring(index) => {
      availability_zone = var.availability_zones[index]
      cidr_block        = cidr
      index             = index
    }
  }
}
