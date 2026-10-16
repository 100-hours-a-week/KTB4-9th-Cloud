resource "aws_cloudwatch_log_group" "service" {
  for_each = local.ecr_repositories

  name              = "/ecs/${local.name_prefix}/${each.key}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Name    = "/ecs/${local.name_prefix}/${each.key}"
    Service = each.key
  }
}

resource "aws_cloudwatch_log_group" "stateful" {
  for_each = local.stateful_services

  name              = "/ecs/${local.name_prefix}/${each.key}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = { Service = each.key }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.name_prefix}/judge-worker"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = { Service = "judge-worker" }
}

