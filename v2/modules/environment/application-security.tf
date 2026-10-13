locals {
  application_security_groups = toset(["spring", "fastapi", "judge-api"])
  data_security_groups        = toset(["rds-mysql", "backend-valkey", "ai-postgres", "judge-postgres", "judge-redis"])
}

resource "aws_security_group" "application" {
  for_each = local.application_security_groups

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "Security group for ${each.key}"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-${each.key}-sg" }
}

resource "aws_security_group" "data" {
  for_each = local.data_security_groups

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "Security group for ${each.key}"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-${each.key}-sg" }
}

resource "aws_security_group" "worker_task" {
  name        = "${local.name_prefix}-judge-worker-task-sg"
  description = "Security group for Judge Worker tasks"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-judge-worker-task-sg" }
}

resource "aws_security_group" "worker_host" {
  name        = "${local.name_prefix}-judge-worker-host-sg"
  description = "Security group for Judge Worker ECS hosts"
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name_prefix}-judge-worker-host-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "spring_from_alb" {
  security_group_id            = aws_security_group.application["spring"].id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "stage_service_from_alb" {
  for_each = local.stage_additional_target_services

  security_group_id            = aws_security_group.application[each.key].id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "fastapi_from_spring" {
  security_group_id            = aws_security_group.application["fastapi"].id
  referenced_security_group_id = aws_security_group.application["spring"].id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "spring_from_fastapi" {
  security_group_id            = aws_security_group.application["spring"].id
  referenced_security_group_id = aws_security_group.application["fastapi"].id
  ip_protocol                  = "tcp"
  from_port                    = var.spring_container_port
  to_port                      = var.spring_container_port
}

resource "aws_vpc_security_group_ingress_rule" "judge_api" {
  for_each = toset(["spring", "fastapi"])

  security_group_id            = aws_security_group.application["judge-api"].id
  referenced_security_group_id = aws_security_group.application[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = var.judge_api_container_port
  to_port                      = var.judge_api_container_port
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_spring" {
  security_group_id            = aws_security_group.data["rds-mysql"].id
  referenced_security_group_id = aws_security_group.application["spring"].id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ssm_tunnel" {
  count = var.environment == "stage" ? 1 : 0

  security_group_id            = aws_security_group.data["rds-mysql"].id
  referenced_security_group_id = aws_security_group.data["ai-postgres"].id
  description                  = "Allow Stage RDS access through the SSM tunnel host"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_spring" {
  for_each = toset(["6379", "6380"])

  security_group_id            = aws_security_group.data["backend-valkey"].id
  referenced_security_group_id = aws_security_group.application["spring"].id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_vpc_security_group_ingress_rule" "ai_postgres_from_fastapi" {
  security_group_id            = aws_security_group.data["ai-postgres"].id
  referenced_security_group_id = aws_security_group.application["fastapi"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "judge_postgres_from_api" {
  security_group_id            = aws_security_group.data["judge-postgres"].id
  referenced_security_group_id = aws_security_group.application["judge-api"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "judge_redis_from_api" {
  security_group_id            = aws_security_group.data["judge-redis"].id
  referenced_security_group_id = aws_security_group.application["judge-api"].id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_vpc_security_group_ingress_rule" "judge_postgres_from_worker" {
  security_group_id            = aws_security_group.data["judge-postgres"].id
  referenced_security_group_id = aws_security_group.worker_task.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "judge_redis_from_worker" {
  security_group_id            = aws_security_group.data["judge-redis"].id
  referenced_security_group_id = aws_security_group.worker_task.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_vpc_security_group_egress_rule" "application_all" {
  for_each = aws_security_group.application

  security_group_id = each.value.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "data_all" {
  for_each = aws_security_group.data

  security_group_id = each.value.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "worker_postgres" {
  security_group_id            = aws_security_group.worker_task.id
  referenced_security_group_id = aws_security_group.data["judge-postgres"].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "worker_redis" {
  security_group_id            = aws_security_group.worker_task.id
  referenced_security_group_id = aws_security_group.data["judge-redis"].id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_vpc_security_group_egress_rule" "worker_dns" {
  for_each = toset(["tcp", "udp"])

  security_group_id = aws_security_group.worker_task.id
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "worker_host_https" {
  security_group_id = aws_security_group.worker_host.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "worker_host_dns" {
  for_each = toset(["tcp", "udp"])

  security_group_id = aws_security_group.worker_host.id
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
}
