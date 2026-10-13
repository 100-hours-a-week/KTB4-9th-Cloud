data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "stateful_execution" {
  for_each = local.stateful_services

  name               = "${local.name_prefix}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "stateful_execution" {
  for_each = local.stateful_services

  role       = aws_iam_role.stateful_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "stateful_secret" {
  for_each = local.stateful_services

  name = "read-own-runtime-secret"
  role = aws_iam_role.stateful_execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.service[each.key].arn]
    }]
  })
}

resource "aws_iam_role" "stateful_task" {
  for_each = local.stateful_services

  name               = "${local.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy" "stateful_exec" {
  for_each = local.stateful_services

  name = "ecs-exec"
  role = aws_iam_role.stateful_task[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

locals {
  application_secret_access = {
    spring    = ["spring"]
    fastapi   = ["fastapi", "ai-postgres"]
    judge-api = ["judge-api", "judge-postgres", "judge-redis"]
  }

  worker_secret_access = ["judge-api", "judge-postgres", "judge-redis"]
}

resource "aws_iam_role" "application_execution" {
  for_each = local.application_services

  name               = "${local.name_prefix}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "application_execution" {
  for_each = local.application_services

  role       = aws_iam_role.application_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "application_secret" {
  for_each = local.application_services

  name = "read-runtime-secrets"
  role = aws_iam_role.application_execution[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [for secret_key in local.application_secret_access[each.key] : aws_secretsmanager_secret.service[secret_key].arn]
    }]
  })
}

resource "aws_iam_role" "application_task" {
  for_each = local.application_services

  name               = "${local.name_prefix}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy" "application_exec" {
  for_each = local.application_services

  name = "ecs-exec"
  role = aws_iam_role.application_task[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "spring_valkey_connect" {
  name = "connect-backend-valkey"
  role = aws_iam_role.application_task["spring"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["elasticache:Connect"]
      Resource = [aws_elasticache_serverless_cache.backend.arn, aws_elasticache_user.spring.arn]
    }]
  })
}

resource "aws_iam_role" "worker_execution" {
  name               = "${local.name_prefix}-judge-worker-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "worker_execution" {
  role       = aws_iam_role.worker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "worker_secrets" {
  name = "read-worker-runtime-secrets"
  role = aws_iam_role.worker_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [for secret_key in local.worker_secret_access : aws_secretsmanager_secret.service[secret_key].arn]
    }]
  })
}

resource "aws_iam_role" "worker_task" {
  name               = "${local.name_prefix}-judge-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}
