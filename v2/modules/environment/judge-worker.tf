locals {
  worker_environment = [
    { name = "POSTGRES_HOST", value = "judge-postgres" },
    { name = "POSTGRES_PORT", value = "5432" },
    { name = "REDIS_HOST", value = "judge-redis" },
    { name = "REDIS_PORT", value = "6379" },
    { name = "RAILS_ENV", value = "production" },
    { name = "RESQUE_NAMESPACE", value = "${var.environment}:judge0" },
    { name = "COUNT", value = "2" },
    { name = "INTERVAL", value = "0.1" },
  ]

  worker_secrets = [
    { name = "SECRET_KEY_BASE", valueFrom = "${aws_secretsmanager_secret.service["judge-api"].arn}:secret_key_base::" },
    { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:username::" },
    { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:password::" },
    { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:database::" },
    { name = "REDIS_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-redis"].arn}:password::" },
  ]
}

resource "aws_ecs_task_definition" "judge_worker" {
  for_each = local.enabled_judge_worker

  family                   = "${local.name_prefix}-judge-worker"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = aws_iam_role.worker_execution.arn
  task_role_arn            = aws_iam_role.worker_task.arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  volume { name = "tmp" }

  container_definitions = jsonencode([{
    name                   = "judge-worker"
    image                  = local.worker_container_image
    command                = local.worker_container_command
    essential              = true
    privileged             = true
    readonlyRootFilesystem = false
    stopTimeout            = 120
    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]
    environment = local.worker_environment
    secrets     = local.worker_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])

  tags = { Service = "judge-worker" }
}

resource "aws_ecs_service" "judge_worker" {
  for_each = local.enabled_judge_worker

  name                               = "${local.name_prefix}-judge-worker"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.judge_worker[each.key].arn
  desired_count                      = var.judge_worker_desired_count
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = false

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.worker_on_demand[0].name
    base              = 1
    weight            = 0
  }

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.worker_spot[0].name
    base              = 0
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = values(var.private_subnet_ids)
    security_groups  = [aws_security_group.worker_task.id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn
  }

  placement_constraints { type = "distinctInstance" }

  lifecycle {
    ignore_changes = [task_definition]

    precondition {
      condition     = var.judge_worker_desired_count <= 1 + var.worker_spot_max_size
      error_message = "judge_worker_desired_count는 On-Demand 1대와 Spot 최대 용량의 합을 초과할 수 없습니다."
    }
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_autoscaling_group.worker_on_demand,
    aws_autoscaling_group.worker_spot,
  ]
}
