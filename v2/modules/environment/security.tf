resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for the public v2 application load balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP only from CloudFront origin-facing addresses"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_public_https" {
  count = var.environment == "stage" ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "Temporary public HTTPS access for stage service testing"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow outbound traffic until service ports are defined"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

