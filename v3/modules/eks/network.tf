resource "aws_subnet" "eks" {
  for_each = var.subnets

  vpc_id                  = var.vpc_id
  availability_zone       = each.value.availability_zone
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.cluster_name}-eks-${each.key}"
    Tier                                        = "eks"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# 기존 Route Table에 연결만 추가하고 Route는 변경하지 않는다.
resource "aws_route_table_association" "eks" {
  for_each = var.subnets

  subnet_id      = aws_subnet.eks[each.key].id
  route_table_id = var.private_route_table_ids[each.key]
}
