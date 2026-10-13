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

  stateful_container_definitions = {
    for key, service in local.enabled_stateful_services : key => jsonencode([merge({
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
        sourceVolume  = "data"
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
    } : {})])
  }
}

resource "aws_ecs_task_definition" "stateful" {
  for_each = local.enabled_stateful_services

  family                   = "${local.name_prefix}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.stateful_execution[each.key].arn
  task_role_arn            = aws_iam_role.stateful_task[each.key].arn
  container_definitions    = local.stateful_container_definitions[each.key]

  volume {
    name      = "data"
    host_path = each.value.mount_path
  }

  tags = { Service = each.key }
}

resource "aws_ecs_service" "stateful" {
  for_each = local.enabled_stateful_services

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

  network_configuration {
    subnets          = [var.private_subnet_ids[each.value.index]]
    security_groups  = [aws_security_group.data[each.key].id]
    assign_public_ip = false
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:role == ${each.key}"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = each.key
      discovery_name = each.key
      client_alias {
        dns_name = each.key
        port     = each.value.port
      }
    }
  }

  depends_on = [aws_volume_attachment.stateful]
}
