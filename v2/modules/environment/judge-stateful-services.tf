locals {
  stateful_container_environment = {
    ai-postgres = [
      { name = "POSTGRES_DB", value = "cosmos" },
      { name = "PGDATA", value = "/var/lib/postgresql/data/pgdata" },
    ]
    judge-postgres = [
      { name = "PGDATA", value = "/var/lib/postgresql/data/pgdata" },
    ]
    judge-redis = []
  }

  stateful_container_secrets = {
    ai-postgres = [
      { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.service["ai-postgres"].arn}:username::" },
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["ai-postgres"].arn}:password::" },
    ]
    judge-postgres = [
      { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:username::" },
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:password::" },
      { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:database::" },
    ]
    judge-redis = [
      { name = "REDIS_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-redis"].arn}:password::" },
    ]
  }

  stateful_primary_container_definitions = {
    for key, service in local.stateful_services : key => merge({
      name                   = key
      image                  = service.image
      essential              = true
      memoryReservation      = service.memory_reservation
      readonlyRootFilesystem = false
      portMappings = [{
        name          = key
        containerPort = service.port
        hostPort      = service.port
        protocol      = "tcp"
      }]
      mountPoints = [{
        sourceVolume  = service.volume_name
        containerPath = service.mount_path
        readOnly      = false
      }]
      healthCheck = {
        command     = service.health_command
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.stateful[key].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      environment = local.stateful_container_environment[key]
      secrets     = local.stateful_container_secrets[key]
      }, key == "judge-redis" ? {
      command = ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$REDIS_PASSWORD\""]
    } : {})
  }

  redis_exporter_container_definition = {
    name                   = "redis-exporter"
    image                  = "oliver006/redis_exporter:v1.93.0"
    essential              = false
    memoryReservation      = 64
    readonlyRootFilesystem = true
    portMappings = [{
      name          = "redis-exporter"
      containerPort = 9121
      hostPort      = 9121
      protocol      = "tcp"
    }]
    environment = [
      { name = "REDIS_EXPORTER_CHECK_SINGLE_KEYS", value = "db0=stage:judge0:queue:1.13.1" },
      { name = "REDIS_EXPORTER_LOG_FORMAT", value = "json" },
      { name = "REDIS_ADDR", value = "redis://127.0.0.1:6379" },
    ]
    secrets = local.stateful_container_secrets["judge-redis"]
    dependsOn = [{
      containerName = "judge-redis"
      condition     = "HEALTHY"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.stateful["judge-redis"].name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "redis-exporter"
      }
    }
  }

  stateful_container_definitions = {
    for group_key, group in local.enabled_stateful_task_groups : group_key => jsonencode(concat(
      [for service_key in group.service_keys : local.stateful_primary_container_definitions[service_key]],
      group_key == "judge-postgres" ? [local.redis_exporter_container_definition] : [],
    ))
  }
}

resource "aws_ecs_task_definition" "stateful" {
  for_each = local.enabled_stateful_task_groups

  family                   = "${local.name_prefix}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.stateful_execution[each.key].arn
  task_role_arn            = aws_iam_role.stateful_task[each.key].arn
  container_definitions    = local.stateful_container_definitions[each.key]

  dynamic "volume" {
    for_each = toset(each.value.service_keys)
    content {
      name      = local.stateful_services[volume.value].volume_name
      host_path = local.stateful_services[volume.value].host_mount_path
    }
  }

  tags = { Service = each.key }
}

resource "aws_ecs_service" "stateful" {
  for_each = local.enabled_stateful_task_groups

  name                               = "${local.name_prefix}-${each.key}"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.stateful[each.key].arn
  desired_count                      = 1
  launch_type                        = "EC2"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  network_configuration {
    subnets          = [var.private_subnet_ids[each.value.index]]
    security_groups  = [for service_key in each.value.service_keys : aws_security_group.data[service_key].id]
    assign_public_ip = false
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:stateful == true"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    dynamic "service" {
      for_each = toset(each.value.service_keys)
      content {
        port_name      = service.value
        discovery_name = service.value
        client_alias {
          dns_name = service.value
          port     = local.stateful_services[service.value].port
        }
      }
    }
  }

  depends_on = [aws_volume_attachment.stateful]
}
