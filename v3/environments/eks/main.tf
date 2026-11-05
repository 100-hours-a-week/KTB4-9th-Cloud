# v2 Shared가 관리하는 VPC는 읽기만 한다.
data "aws_vpc" "shared" {
  cidr_block = "10.20.0.0/16"

  tags = {
    Project = "cosmos"
  }
}

data "aws_route_table" "private_a" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "cosmos-v2-shared-private-1-rt"
  }
}

data "aws_route_table" "private_c" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "cosmos-v2-shared-private-2-rt"
  }
}

module "eks" {
  source = "../../modules/eks"

  vpc_id                  = data.aws_vpc.shared.id
  private_route_table_ids = { a = data.aws_route_table.private_a.id, c = data.aws_route_table.private_c.id }
  public_access_cidrs     = var.public_access_cidrs
}
