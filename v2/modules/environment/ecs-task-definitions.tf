locals {
  application_environment = {
    spring = [
      { name = "APP_REGION", value = "ap-northeast-2" },
      { name = "APP_VERSION", value = "v2" },
      { name = "SPRING_PROFILES_ACTIVE", value = "prod" },
      { name = "DB_URL", value = "jdbc:mysql://${aws_db_instance.mysql.address}:3306/cosmos?useSSL=false&allowPublicKeyRetrieval=true&characterEncoding=UTF-8&serverTimezone=Asia/Seoul" },
      { name = "AI_SERVER_BASE_URL", value = "https://stage-ai.${var.domain_name}" },
      { name = "JUDGE0_BASE_URL", value = "https://stage-judge.${var.domain_name}" },
      { name = "FRONTEND_BASE_URL", value = var.enable_public_dns_cutover ? "https://${var.domain_name}" : (var.environment == "stage" ? "https://stage.${var.domain_name}" : "https://${var.domain_name}") },
      { name = "MANAGEMENT_PORT", value = "9091" },
      { name = "SENTRY_ENVIRONMENT", value = var.environment },
      { name = "SPRING_JPA_OPEN_IN_VIEW", value = "true" },
    ]
    fastapi = [
      { name = "DB_HOST", value = "ai-postgres" },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = "cosmos" },
      { name = "DB_ECHO", value = "false" },
      { name = "DB_POOL_SIZE", value = "5" },
      { name = "DB_MAX_OVERFLOW", value = "5" },
      { name = "BACKEND_URL", value = "http://spring:${var.spring_container_port}/api" },
      { name = "JUDGE0_URL", value = "http://judge-api:${var.judge_api_container_port}" },
      { name = "MOCK_LLM", value = "false" },
      { name = "BATCH_ENABLED", value = "true" },
      { name = "BATCH_TIMEZONE", value = "Asia/Seoul" },
      { name = "BATCH_CONCURRENCY", value = "5" },
      { name = "LOG_LEVEL", value = "INFO" },
    ]
    judge-api = [
      { name = "POSTGRES_HOST", value = "judge-postgres" },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "REDIS_HOST", value = "judge-redis" },
      { name = "REDIS_PORT", value = "6379" },
      { name = "RAILS_ENV", value = "production" },
      { name = "RESQUE_NAMESPACE", value = "${var.environment}:judge0" },
      { name = "PORT", value = tostring(var.judge_api_container_port) },
    ]
  }

  application_secrets = {
    spring = [
      { name = "DB_USERNAME", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:db_username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:db_password::" },
      { name = "KAKAO_CLIENT_ID", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:kakao_client_id::" },
      { name = "KAKAO_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:kakao_client_secret::" },
      { name = "KAKAO_REDIRECT_URI", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:kakao_redirect_uri::" },
      { name = "JWT_SECRET", valueFrom = "${aws_secretsmanager_secret.service["spring"].arn}:jwt_secret::" },
    ]
    fastapi = [
      { name = "DB_USER", valueFrom = "${aws_secretsmanager_secret.service["ai-postgres"].arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["ai-postgres"].arn}:password::" },
      { name = "GEMINI_API_KEY", valueFrom = "${aws_secretsmanager_secret.service["fastapi"].arn}:gemini_api_key::" },
    ]
    judge-api = [
      { name = "SECRET_KEY_BASE", valueFrom = "${aws_secretsmanager_secret.service["judge-api"].arn}:secret_key_base::" },
      { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:username::" },
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:password::" },
      { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.service["judge-postgres"].arn}:database::" },
      { name = "REDIS_PASSWORD", valueFrom = "${aws_secretsmanager_secret.service["judge-redis"].arn}:password::" },
    ]
  }
}

resource "aws_ecs_task_definition" "application" {
  for_each = local.enabled_application_services

  lifecycle {
    create_before_destroy = true
  }

  family                   = "${local.name_prefix}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = aws_iam_role.application_execution[each.key].arn
  task_role_arn            = aws_iam_role.application_task[each.key].arn

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  volume { name = "tmp" }

  container_definitions = jsonencode([
    merge(
      {
        name                   = each.key
        image                  = local.application_container_images[each.key]
        command                = local.application_container_commands[each.key]
        essential              = true
        readonlyRootFilesystem = each.key != "judge-api"
        portMappings = concat([{
          name          = each.key
          containerPort = each.value.port
          hostPort      = each.value.port
          protocol      = "tcp"
          appProtocol   = "http"
          }], each.key == "spring" ? [{
          name          = "spring-metrics"
          containerPort = 9091
          hostPort      = 9091
          protocol      = "tcp"
          appProtocol   = "http"
        }] : [])
        # Judge0 image runs as uid 1000 and already has a writable image /tmp.
        # A fresh ECS volume mounted there is root-owned and makes Ruby Dir.tmpdir fail.
        mountPoints = each.key == "judge-api" ? [] : [
          { sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }
        ]
        environment = local.application_environment[each.key]
        secrets     = local.application_secrets[each.key]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "ecs"
          }
        }
      },
      var.environment == "prod" && each.key != "spring" ? {
        healthCheck = {
          command     = each.value.health_command
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = 60
        }
      } : {}
    )
  ])

  tags = { Service = each.key }
}
