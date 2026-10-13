mock_provider "aws" {
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
}

variables {
  environment                       = "stage"
  vpc_id                            = "vpc-0123456789abcdef0"
  route53_zone_id                   = "Z0123456789"
  cloudfront_certificate_arn        = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  regional_wildcard_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/regional-test"

  public_subnet_ids = {
    "0" = "subnet-public-a"
    "1" = "subnet-public-c"
  }

  private_subnet_ids = {
    "0" = "subnet-private-a"
    "1" = "subnet-private-c"
  }

  data_subnet_ids = {
    "0" = "subnet-data-a"
    "1" = "subnet-data-c"
  }

  ecr_repository_urls = {
    spring  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/cosmos-v2/spring"
    fastapi = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/cosmos-v2/fastapi"
    judge   = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/cosmos-v2/judge"
  }

  ecr_repository_arns = {
    spring  = "arn:aws:ecr:ap-northeast-2:123456789012:repository/cosmos-v2/spring"
    fastapi = "arn:aws:ecr:ap-northeast-2:123456789012:repository/cosmos-v2/fastapi"
    judge   = "arn:aws:ecr:ap-northeast-2:123456789012:repository/cosmos-v2/judge"
  }
}

run "stage_환경_경계가_모든_런타임_이름에_적용된다" {
  command = plan

  assert {
    condition     = local.name_prefix == "cosmos-v2-stage"
    error_message = "stage 이름 접두사는 cosmos-v2-stage여야 합니다."
  }

  assert {
    condition     = aws_ecs_cluster.main.name == "cosmos-v2-stage-cluster"
    error_message = "ECS cluster 이름에 stage 환경이 포함되어야 합니다."
  }

  assert {
    condition     = aws_service_discovery_http_namespace.main.name == "stage.cosmos-v2.local"
    error_message = "Service Connect namespace는 stage 환경 전용이어야 합니다."
  }

  assert {
    condition = toset([for secret in aws_secretsmanager_secret.service : secret.name]) == toset([
      "/cosmos-v2/stage/spring",
      "/cosmos-v2/stage/fastapi",
      "/cosmos-v2/stage/ai-postgres",
      "/cosmos-v2/stage/judge-api",
      "/cosmos-v2/stage/judge-postgres",
      "/cosmos-v2/stage/judge-redis",
      "/cosmos-v2/stage/judge-worker",
    ])
    error_message = "Secret metadata는 stage 경로 7개를 사용해야 합니다."
  }

  assert {
    condition     = aws_cloudwatch_log_group.service["spring"].name == "/ecs/cosmos-v2-stage/spring" && aws_cloudwatch_log_group.worker.name == "/ecs/cosmos-v2-stage/judge-worker"
    error_message = "CloudWatch Log Group은 stage 접두사를 사용해야 합니다."
  }

  assert {
    condition     = aws_elasticache_user.spring.user_id == "cosmos-v2-stage-spring" && aws_elasticache_user_group.backend.user_group_id == "cosmos-v2-stage-backend"
    error_message = "Valkey user와 group은 stage 환경별로 분리되어야 합니다."
  }
}

run "지원하지_않는_환경명은_거부한다" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "공유_ECR_입력을_런타임에_그대로_사용한다" {
  command = plan

  assert {
    condition     = output.ecr_repository_urls == var.ecr_repository_urls && output.ecr_repository_arns == var.ecr_repository_arns
    error_message = "environment module은 공유 ECR map을 변경 없이 사용해야 합니다."
  }
}

run "ALB_인증서가_서울_리전이_아니면_거부한다" {
  command = plan

  variables {
    regional_wildcard_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  }

  expect_failures = [var.regional_wildcard_certificate_arn]
}
