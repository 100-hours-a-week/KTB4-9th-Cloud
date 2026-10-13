variables {
  vpc_id                            = "vpc-test"
  route53_zone_id                   = "Z0123456789"
  cloudfront_certificate_arn        = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  regional_wildcard_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/regional-test"
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
    values = { value = "ami-test" }
  }
}

run "기본_런타임은_prod_환경과_비활성_서비스를_사용한다" {
  command = plan

  assert {
    condition     = var.environment == "prod" && local.name_prefix == "cosmos-v2-prod"
    error_message = "기본 런타임 환경은 prod여야 합니다."
  }

  assert {
    condition     = !var.enable_phase2_services && !var.enable_stateful_services && !var.enable_judge_worker_capacity && !var.enable_judge_worker
    error_message = "애플리케이션과 Worker는 기본 비활성화여야 합니다."
  }
}

run "ECS_cluster와_환경별_로그를_구성한다" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.main.name == "cosmos-v2-prod-cluster"
    error_message = "ECS cluster 이름이 환경 접두사를 사용해야 합니다."
  }

  assert {
    condition = toset([for log in aws_cloudwatch_log_group.service : log.name]) == toset([
      "/ecs/cosmos-v2-prod/spring",
      "/ecs/cosmos-v2-prod/fastapi",
      "/ecs/cosmos-v2-prod/judge-api",
    ])
    error_message = "애플리케이션 로그 그룹 3개가 환경별로 필요합니다."
  }
}

run "ALB는_공유_Public_subnet과_환경별_SG를_사용한다" {
  command = plan

  assert {
    condition     = aws_lb.main.name == "cosmos-v2-prod-alb" && toset(aws_lb.main.subnets) == toset(values(var.public_subnet_ids))
    error_message = "ALB는 환경 이름과 공유 Public subnet 두 개를 사용해야 합니다."
  }

  assert {
    condition     = aws_security_group.alb.vpc_id == var.vpc_id
    error_message = "ALB SG는 전달받은 공유 VPC에 생성되어야 합니다."
  }
}

run "잘못된_환경과_로그_보존값을_거부한다" {
  command = plan
  variables {
    environment                   = "dev"
    cloudwatch_log_retention_days = 31
  }
  expect_failures = [var.environment, var.cloudwatch_log_retention_days]
}
