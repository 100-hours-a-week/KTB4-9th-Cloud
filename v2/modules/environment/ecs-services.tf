resource "aws_ecs_service" "application" {
  for_each = local.enabled_application_services

  name                               = "${local.name_prefix}-${each.key}"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.application[each.key].arn
  desired_count                      = var.application_desired_count
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = values(var.private_subnet_ids)
    security_groups  = [aws_security_group.application[each.key].id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    dynamic "service" {
      for_each = each.value.server ? [each.value] : []
      content {
        port_name      = each.key
        discovery_name = each.key
        client_alias {
          dns_name = each.key
          port     = each.value.port
        }
      }
    }
  }

  dynamic "load_balancer" {
    for_each = each.key == "spring" || var.environment == "stage" ? [1] : []
    content {
      target_group_arn = each.key == "spring" ? aws_lb_target_group.spring.arn : aws_lb_target_group.stage_service[each.key].arn
      container_name   = each.key
      container_port   = each.value.port
    }
  }

  depends_on = [aws_lb_listener_rule.spring, aws_lb_listener_rule.stage_service]
}
