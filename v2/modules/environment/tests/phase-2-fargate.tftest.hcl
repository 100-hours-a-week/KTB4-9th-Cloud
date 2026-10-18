variables {
  vpc_id                            = "vpc-test"
  route53_zone_id                   = "Z0123456789"
  cloudfront_certificate_arn        = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  regional_wildcard_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/regional-test"
  github_oidc_provider_arn          = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  public_subnet_ids                 = { "0" = "subnet-public-a", "1" = "subnet-public-c" }
  private_subnet_ids                = { "0" = "subnet-private-a", "1" = "subnet-private-c" }
  data_subnet_ids                   = { "0" = "subnet-data-a", "1" = "subnet-data-c" }
  ecr_repository_urls = {
    spring = "ecr/spring", fastapi = "ecr/fastapi", judge = "ecr/judge"
  }
  ecr_repository_arns = {
    spring = "arn:spring", fastapi = "arn:fastapi", judge = "arn:judge"
  }
}

mock_provider "aws" {
  override_resource {
    target = aws_secretsmanager_secret.service
    values = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:test" }
  }
  override_resource {
    target = aws_db_instance.mysql
    values = {
      address = "mysql.internal"
      port    = 3306
    }
  }
  override_data {
    target = data.aws_iam_policy_document.ecs_task_execution
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.ecs_tasks_assume_role
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.ec2_assume_role
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.dlm_assume_role
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_ssm_parameter.ecs_optimized_al2023
    values = { value = "ami-0123456789abcdef0" }
  }
  override_resource {
    target = aws_lb.main
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/cosmos-v2-prod-alb/1234567890abcdef" }
  }
  override_resource {
    target = aws_lb_listener.http
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/cosmos-v2-prod-alb/1234567890abcdef/1234567890abcdef" }
  }
  override_resource {
    target = aws_lb_listener.https
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/cosmos-v2-stage-alb/1234567890abcdef/abcdef1234567890" }
  }
  override_resource {
    target = aws_lb_target_group.spring
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/cosmos-v2-prod-spring/1234567890abcdef" }
  }
  override_resource {
    target = aws_lb_target_group.stage_service
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/cosmos-v2-stage-service/abcdef1234567890" }
  }
  override_resource {
    target = aws_cloudfront_function.spa_rewrite
    values = { arn = "arn:aws:cloudfront::123456789012:function/cosmos-v2-stage-spa-rewrite" }
  }
  override_resource {
    target = aws_ecs_task_definition.application
    values = { arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/cosmos-v2-prod-app:1" }
  }
  override_resource {
    target = aws_iam_role.application_execution
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-app-execution" }
  }
  override_resource {
    target = aws_iam_role.application_task
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-app-task" }
  }
  override_resource {
    target = aws_iam_role.dlm
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-dlm" }
  }
}

run "애플리케이션_기본값은_비활성_단일_Task_설계다" {
  command = plan

  assert {
    condition = (
      !var.enable_phase2_services &&
      var.application_desired_count == 1 &&
      local.application_services.spring.port == 8080 &&
      local.application_services.spring.cpu == 1024 &&
      local.application_services.spring.memory == 2048 &&
      local.application_services.fastapi.port == 8000 &&
      local.application_services.fastapi.cpu == 512 &&
      local.application_services["judge-api"].port == 2358
    )
    error_message = "애플리케이션 기본 port/capacity와 안전한 비활성 상태가 설계와 일치해야 합니다."
  }

  assert {
    condition     = length(aws_ecs_task_definition.application) == 0 && length(aws_ecs_service.application) == 0 && length(aws_lb_listener_rule.spring) == 0
    error_message = "기본 bootstrap에서는 애플리케이션 Task/Service와 listener rule을 만들지 않아야 합니다."
  }
}

run "digest없이_Fargate를_활성화하면_거부한다" {
  command = plan
  variables { enable_phase2_services = true }
  expect_failures = [var.spring_image_digest, var.fastapi_image_digest, var.judge_image_digest]
}

run "서비스별_IAM은_Secret과_Valkey_권한을_분리한다" {
  command = plan

  assert {
    condition     = length(aws_iam_role.application_execution) == 3 && length(aws_iam_role.application_task) == 3
    error_message = "애플리케이션별 execution/task role이 각각 필요합니다."
  }

  assert {
    condition = (
      local.application_secret_access.spring == ["spring"] &&
      local.application_secret_access.fastapi == ["fastapi", "ai-postgres"] &&
      local.application_secret_access["judge-api"] == ["judge-api", "judge-postgres", "judge-redis"] &&
      aws_iam_role_policy.spring_valkey_connect.name == "connect-backend-valkey"
    )
    error_message = "각 execution role은 필요한 Secret만 읽고 기존 Spring Valkey IAM metadata는 보존해야 합니다."
  }
}

run "Fargate_Service는_내부_topology와_Spring_ALB만_구성한다" {
  command = apply

  variables {
    enable_phase2_services = true
    spring_image_digest    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fastapi_image_digest   = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    judge_image_digest     = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }

  assert {
    condition     = length(aws_ecs_task_definition.application) == 3 && length(aws_ecs_service.application) == 3
    error_message = "활성화 시 애플리케이션 Task/Service 3개가 필요합니다."
  }

  assert {
    condition = (
      local.application_container_images["judge-api"] == "ecr/judge@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" &&
      local.application_container_commands["judge-api"] == tolist(["./scripts/server"])
    )
    error_message = "Judge API는 공용 judge image와 server 실행 명령을 사용해야 합니다."
  }

  assert {
    condition = alltrue([
      for key, task in aws_ecs_task_definition.application :
      task.requires_compatibilities == toset(["FARGATE"]) &&
      task.network_mode == "awsvpc" &&
      task.runtime_platform[0].cpu_architecture == "X86_64" &&
      can(regex("^sha256:[0-9a-f]{64}$", local.application_services[key].image_digest))
    ])
    error_message = "Fargate Task는 digest, awsvpc, X86_64, readonly root와 HTTP named port를 사용해야 합니다."
  }

  assert {
    condition = {
      for item in local.application_environment.spring : item.name => item.value
      } == {
      SPRING_PROFILES_ACTIVE  = "stage"
      DB_URL                  = "jdbc:mysql://mysql.internal:3306/cosmos"
      AI_SERVER_BASE_URL      = "http://fastapi:8000"
      JUDGE0_BASE_URL         = "http://judge-api:2358"
      FRONTEND_BASE_URL       = "https://cosmoscode.site"
      SENTRY_ENVIRONMENT      = "prod"
      SPRING_JPA_OPEN_IN_VIEW = "true"
      } && {
      for item in local.application_environment.fastapi : item.name => item.value
      } == {
      DB_HOST           = "ai-postgres"
      DB_PORT           = "5432"
      DB_NAME           = "cosmos"
      DB_ECHO           = "false"
      DB_POOL_SIZE      = "5"
      DB_MAX_OVERFLOW   = "5"
      BACKEND_URL       = "http://spring:8080/api"
      JUDGE0_URL        = "http://judge-api:2358"
      MOCK_LLM          = "false"
      BATCH_ENABLED     = "true"
      BATCH_TIMEZONE    = "Asia/Seoul"
      BATCH_CONCURRENCY = "5"
      LOG_LEVEL         = "INFO"
    }
    error_message = "Spring과 FastAPI 비민감 환경 변수는 실제 애플리케이션 설정 이름과 일치해야 합니다."
  }

  assert {
    condition = (
      toset([for secret in local.application_secrets.spring : secret.name]) == toset([
        "DB_USERNAME", "DB_PASSWORD", "KAKAO_CLIENT_ID",
        "KAKAO_CLIENT_SECRET", "KAKAO_REDIRECT_URI", "JWT_SECRET",
      ]) &&
      toset([for secret in local.application_secrets.fastapi : secret.name]) == toset([
        "DB_USER", "DB_PASSWORD", "GEMINI_API_KEY",
      ]) &&
      toset([for secret in local.application_secrets["judge-api"] : secret.name]) == toset([
        "SECRET_KEY_BASE", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "REDIS_PASSWORD",
      ]) &&
      length(setintersection(
        toset(flatten([for secrets in values(local.application_secrets) : [for secret in secrets : secret.name]])),
        toset(["FASTAPI_SECRET_JSON", "JUDGE_API_SECRET_JSON"]),
      )) == 0
    )
    error_message = "애플리케이션 Secret은 필수 JSON key를 실제 환경 변수 이름으로 개별 주입해야 합니다."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.application["spring"].container_definitions)[0].readonlyRootFilesystem &&
      jsondecode(aws_ecs_task_definition.application["fastapi"].container_definitions)[0].readonlyRootFilesystem &&
      !jsondecode(aws_ecs_task_definition.application["judge-api"].container_definitions)[0].readonlyRootFilesystem
    )
    error_message = "Spring/FastAPI는 read-only root를 유지하고 Judge API만 writable root를 사용해야 합니다."
  }

  assert {
    condition = (
      length(jsondecode(aws_ecs_task_definition.application["spring"].container_definitions)[0].mountPoints) == 1 &&
      jsondecode(aws_ecs_task_definition.application["spring"].container_definitions)[0].mountPoints[0].containerPath == "/tmp" &&
      length(jsondecode(aws_ecs_task_definition.application["fastapi"].container_definitions)[0].mountPoints) == 1 &&
      jsondecode(aws_ecs_task_definition.application["fastapi"].container_definitions)[0].mountPoints[0].containerPath == "/tmp" &&
      length(jsondecode(aws_ecs_task_definition.application["judge-api"].container_definitions)[0].mountPoints) == 0
    )
    error_message = "read-only Spring/FastAPI만 writable /tmp 볼륨을 사용하고 Judge API는 image의 /tmp 권한을 보존해야 합니다."
  }

  assert {
    condition = alltrue([
      for service in aws_ecs_service.application :
      service.desired_count == 1 &&
      service.deployment_minimum_healthy_percent == 100 &&
      service.deployment_maximum_percent == 200 &&
      !service.network_configuration[0].assign_public_ip &&
      length(service.network_configuration[0].subnets) == 2 &&
      one(service.capacity_provider_strategy).capacity_provider == "FARGATE"
    ])
    error_message = "Fargate Service는 private subnet, 단일 task, 100/200 rolling을 사용해야 합니다."
  }

  assert {
    condition = (
      length(aws_ecs_service.application["spring"].load_balancer) == 1 &&
      length(aws_ecs_service.application["fastapi"].load_balancer) == 0 &&
      length(aws_ecs_service.application["judge-api"].load_balancer) == 0 &&
      one(aws_ecs_service.application["spring"].service_connect_configuration[0].service).client_alias[0].dns_name == "spring" &&
      one(aws_ecs_service.application["spring"].service_connect_configuration[0].service).client_alias[0].port == 8080 &&
      one(aws_ecs_service.application["fastapi"].service_connect_configuration[0].service).client_alias[0].dns_name == "fastapi" &&
      one(aws_ecs_service.application["judge-api"].service_connect_configuration[0].service).client_alias[0].dns_name == "judge-api"
    )
    error_message = "Spring만 ALB에 연결되고 세 애플리케이션 모두 내부 server alias를 가져야 합니다."
  }
}

run "Spring_Target_Group과_listener_rule은_안전하게_전환된다" {
  command = plan

  assert {
    condition = (
      aws_lb_target_group.spring.target_type == "ip" &&
      aws_lb_target_group.spring.protocol == "HTTP" &&
      aws_lb_target_group.spring.port == 8080 &&
      aws_lb_target_group.spring.health_check[0].path == "/api/actuator/health" &&
      aws_lb_target_group.spring.health_check[0].matcher == "200" &&
      aws_lb_target_group.spring.deregistration_delay == "30" &&
      !aws_lb_target_group.spring.stickiness[0].enabled &&
      aws_lb_listener.http.default_action[0].fixed_response[0].status_code == "404"
    )
    error_message = "Spring Target Group과 기존 fixed 404 listener 안전 상태가 필요합니다."
  }

  assert {
    condition = (
      length(aws_lb_listener.https) == 0 &&
      length(aws_lb_target_group.stage_service) == 0 &&
      length(aws_lb_listener_rule.stage_service) == 0 &&
      length(aws_vpc_security_group_ingress_rule.alb_public_https) == 0 &&
      length(aws_vpc_security_group_ingress_rule.stage_service_from_alb) == 0
    )
    error_message = "Prod에는 Stage HTTPS listener, 추가 target group, host rule을 만들지 않아야 합니다."
  }
}

run "비활성_Stage는_HTTPS_기반만_만들고_기본_404를_반환한다" {
  command = plan

  variables {
    environment = "stage"
  }

  assert {
    condition = (
      length(aws_lb_listener.https) == 1 &&
      aws_lb_listener.https[0].port == 443 &&
      aws_lb_listener.https[0].protocol == "HTTPS" &&
      aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" &&
      aws_lb_listener.https[0].certificate_arn == var.regional_wildcard_certificate_arn &&
      aws_lb_listener.https[0].default_action[0].fixed_response[0].status_code == "404" &&
      toset(keys(aws_lb_target_group.stage_service)) == toset(["fastapi", "judge-api"]) &&
      length(aws_lb_listener_rule.stage_service) == 0
    )
    error_message = "비활성 Stage는 HTTPS listener와 추가 target group만 준비하고 host forwarding은 만들지 않아야 합니다."
  }

  assert {
    condition = (
      aws_lb_target_group.stage_service["fastapi"].port == 8000 &&
      aws_lb_target_group.stage_service["fastapi"].health_check[0].path == "/health" &&
      aws_lb_target_group.stage_service["judge-api"].port == 2358 &&
      aws_lb_target_group.stage_service["judge-api"].health_check[0].path == "/" &&
      alltrue([
        for target_group in aws_lb_target_group.stage_service :
        target_group.protocol == "HTTP" &&
        target_group.target_type == "ip" &&
        target_group.health_check[0].matcher == "200" &&
        target_group.deregistration_delay == "30" &&
        !target_group.stickiness[0].enabled
      ])
    )
    error_message = "Stage FastAPI/Judge target group의 port와 health check가 런타임 계약과 일치해야 합니다."
  }
}

run "활성_Stage는_세_Host를_각_Target_Group으로_전달한다" {
  command = apply

  variables {
    environment            = "stage"
    enable_phase2_services = true
    spring_image_digest    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fastapi_image_digest   = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    judge_image_digest     = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }

  assert {
    condition = (
      toset(keys(aws_lb_listener_rule.stage_service)) == toset(["spring", "fastapi", "judge-api"]) &&
      aws_lb_listener_rule.stage_service["spring"].priority == 100 &&
      aws_lb_listener_rule.stage_service["fastapi"].priority == 110 &&
      aws_lb_listener_rule.stage_service["judge-api"].priority == 120 &&
      one(aws_lb_listener_rule.stage_service["spring"].condition).host_header[0].values == toset(["stage-be.cosmoscode.site"]) &&
      one(aws_lb_listener_rule.stage_service["fastapi"].condition).host_header[0].values == toset(["stage-ai.cosmoscode.site"]) &&
      one(aws_lb_listener_rule.stage_service["judge-api"].condition).host_header[0].values == toset(["stage-judge.cosmoscode.site"])
    )
    error_message = "Stage HTTPS listener는 고정 priority와 service host로 세 target group을 선택해야 합니다."
  }

  assert {
    condition = (
      toset(keys(aws_lb_listener_rule.stage_swagger_root)) == toset(["fastapi", "judge-api"]) &&
      aws_lb_listener_rule.stage_swagger_root["fastapi"].priority == 105 &&
      aws_lb_listener_rule.stage_swagger_root["judge-api"].priority == 115 &&
      one([for condition in aws_lb_listener_rule.stage_swagger_root["fastapi"].condition : condition.host_header[0].values if length(condition.host_header) > 0]) == toset(["stage-ai.cosmoscode.site"]) &&
      one([for condition in aws_lb_listener_rule.stage_swagger_root["fastapi"].condition : condition.path_pattern[0].values if length(condition.path_pattern) > 0]) == toset(["/"]) &&
      one(aws_lb_listener_rule.stage_swagger_root["fastapi"].action).redirect[0].path == "/docs" &&
      one(aws_lb_listener_rule.stage_swagger_root["judge-api"].action).redirect[0].path == "/docs" &&
      one(aws_lb_listener_rule.stage_swagger_root["fastapi"].action).redirect[0].status_code == "HTTP_302"
    )
    error_message = "AI와 Judge의 Stage 루트 URL은 동일 호스트의 /docs로 리다이렉트되어야 합니다."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.alb_public_https) == 1 &&
      aws_vpc_security_group_ingress_rule.alb_public_https[0].cidr_ipv4 == "0.0.0.0/0" &&
      aws_vpc_security_group_ingress_rule.alb_public_https[0].from_port == 443 &&
      aws_vpc_security_group_ingress_rule.alb_public_https[0].to_port == 443 &&
      toset(keys(aws_vpc_security_group_ingress_rule.stage_service_from_alb)) == toset(["fastapi", "judge-api"]) &&
      aws_vpc_security_group_ingress_rule.stage_service_from_alb["fastapi"].from_port == 8000 &&
      aws_vpc_security_group_ingress_rule.stage_service_from_alb["judge-api"].from_port == 2358
    )
    error_message = "Stage ALB는 public 443을 받고 FastAPI/Judge의 실제 container port로만 전달해야 합니다."
  }

  assert {
    condition = (
      length(aws_ecs_service.application["spring"].load_balancer) == 1 &&
      length(aws_ecs_service.application["fastapi"].load_balancer) == 1 &&
      length(aws_ecs_service.application["judge-api"].load_balancer) == 1 &&
      one(aws_ecs_service.application["spring"].load_balancer).target_group_arn == aws_lb_target_group.spring.arn &&
      one(aws_ecs_service.application["fastapi"].load_balancer).target_group_arn == aws_lb_target_group.stage_service["fastapi"].arn &&
      one(aws_ecs_service.application["judge-api"].load_balancer).target_group_arn == aws_lb_target_group.stage_service["judge-api"].arn &&
      one(aws_ecs_service.application["judge-api"].load_balancer).container_port == 2358
    )
    error_message = "Stage의 세 ECS Service는 각자의 target group과 container port에 연결되어야 합니다."
  }

  assert {
    condition = alltrue([
      for task in aws_ecs_task_definition.application :
      !contains(keys(jsondecode(task.container_definitions)[0]), "healthCheck")
    ])
    error_message = "애플리케이션 container definition은 curl 설치를 가정하는 healthCheck를 포함하지 않아야 합니다."
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.judge_api :
      rule.from_port == 2358 && rule.to_port == 2358
    ])
    error_message = "Judge API 내부 ingress도 실제 2358 포트를 사용해야 합니다."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.ai_postgres_from_fastapi.referenced_security_group_id == aws_security_group.application["fastapi"].id &&
      aws_vpc_security_group_ingress_rule.ai_postgres_from_fastapi.from_port == 5432 &&
      length(aws_vpc_security_group_ingress_rule.rds_from_ssm_tunnel) == 1 &&
      aws_vpc_security_group_ingress_rule.rds_from_ssm_tunnel[0].referenced_security_group_id == aws_security_group.data["ai-postgres"].id &&
      aws_vpc_security_group_ingress_rule.rds_from_ssm_tunnel[0].from_port == 3306 &&
      aws_vpc_security_group_ingress_rule.spring_from_fastapi.referenced_security_group_id == aws_security_group.application["fastapi"].id &&
      aws_vpc_security_group_ingress_rule.spring_from_fastapi.from_port == 8080 &&
      length(aws_vpc_security_group_ingress_rule.valkey_from_spring) == 2
    )
    error_message = "Stage SSM tunnel host는 RDS 3306에 접근하고 FastAPI/Valkey 내부 SG 규칙은 보존되어야 합니다."
  }
}

run "Prod_내부_서비스는_런타임_기반_health_check를_유지한다" {
  command = apply

  variables {
    environment            = "prod"
    enable_phase2_services = true
    spring_image_digest    = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fastapi_image_digest   = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    judge_image_digest     = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.application["spring"].container_definitions)[0]), "healthCheck")
    error_message = "Prod Spring은 ALB health check를 사용하므로 container health check를 중복 실행하지 않아야 합니다."
  }

  assert {
    condition = join("\n", jsondecode(aws_ecs_task_definition.application["fastapi"].container_definitions)[0].healthCheck.command) == join("\n", [
      "CMD-SHELL",
      "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')\"",
    ])
    error_message = "ALB가 없는 Prod FastAPI는 Python 런타임으로 /health readiness를 확인해야 합니다."
  }

  assert {
    condition = join("\n", jsondecode(aws_ecs_task_definition.application["judge-api"].container_definitions)[0].healthCheck.command) == join("\n", [
      "CMD-SHELL",
      "ruby -rnet/http -ruri -e \"exit(Net::HTTP.get_response(URI('http://127.0.0.1:2358/')).is_a?(Net::HTTPSuccess) ? 0 : 1)\"",
    ])
    error_message = "ALB가 없는 Prod Judge API는 Ruby 런타임으로 / readiness를 확인해야 합니다."
  }
}
