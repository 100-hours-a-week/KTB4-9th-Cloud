resource "aws_lb" "main" {
  name                       = "${local.name_prefix}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = values(var.public_subnet_ids)
  enable_deletion_protection = true

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.environment == "stage" ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.regional_wildcard_certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_target_group" "spring" {
  name                 = "${local.name_prefix}-spring"
  port                 = var.spring_container_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = local.application_services.spring.health_path
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Service = "spring" }
}

resource "aws_lb_target_group" "stage_service" {
  for_each = local.stage_additional_target_services

  name                 = "${local.name_prefix}-${each.key}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = each.value.health_path
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Service = each.key }
}

resource "aws_lb_listener_rule" "spring" {
  count = var.enable_phase2_services ? 1 : 0

  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.spring.arn
  }

  condition {
    path_pattern { values = ["/*"] }
  }
}

resource "aws_lb_listener_rule" "stage_service" {
  for_each = local.enabled_stage_service_routes

  listener_arn = aws_lb_listener.https[0].arn
  priority     = each.value.priority

  action {
    type = "forward"
    target_group_arn = each.key == "spring" ? (
      aws_lb_target_group.spring.arn
    ) : aws_lb_target_group.stage_service[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.hostname]
    }
  }
}

resource "aws_lb_listener_rule" "stage_swagger_root" {
  for_each = local.stage_swagger_root_routes

  listener_arn = aws_lb_listener.https[0].arn
  priority     = each.value.priority

  action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      path        = "/docs"
      query       = "#{query}"
      status_code = "HTTP_302"
    }
  }

  condition {
    host_header {
      values = [each.value.hostname]
    }
  }

  condition {
    path_pattern {
      values = ["/"]
    }
  }
}

