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

# v2가 관리하는 RDS·Valkey Security Group에 EKS 파드 접근 규칙만 추가한다.
resource "aws_vpc_security_group_ingress_rule" "rds_from_eks" {
  security_group_id            = var.rds_security_group_id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "EKS cosmos-v3 to RDS"
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_eks" {
  security_group_id            = var.valkey_security_group_id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "EKS cosmos-v3 to Valkey"
}
