# 클러스터 전용 VPC. 운영 VPC와 연결하지 않는다.
variable "name" { type = string }
variable "cidr_prefix" { type = string }

resource "aws_vpc" "main" {
  cidr_block           = "${var.cidr_prefix}.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = var.name }
}

locals {
  azs = { a = "ap-northeast-2a", c = "ap-northeast-2c" }
  net = { a = 0, c = 1 }
}

resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value
  cidr_block              = "${var.cidr_prefix}.${local.net[each.key]}.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${each.key}" }
}

resource "aws_subnet" "data" {
  for_each          = local.azs
  vpc_id            = aws_vpc.main.id
  availability_zone = each.value
  cidr_block        = "${var.cidr_prefix}.${20 + local.net[each.key]}.0/24"
  tags              = { Name = "${var.name}-data-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# 비용을 줄이려고 NAT는 1개만 둔다.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id
  tags          = { Name = var.name }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "data" {
  for_each       = aws_subnet.data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" { value = aws_vpc.main.id }
output "data_subnet_ids" { value = [for s in aws_subnet.data : s.id] }
output "private_route_table_id" { value = aws_route_table.private.id }
