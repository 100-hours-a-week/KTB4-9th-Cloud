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

run "데이터_계층은_공유_Data_subnet과_환경별_SG를_사용한다" {
  command = plan

  assert {
    condition     = toset(aws_db_subnet_group.mysql.subnet_ids) == toset(values(var.data_subnet_ids))
    error_message = "RDS subnet group은 공유 Data subnet 두 개를 사용해야 합니다."
  }

  assert {
    condition     = length(aws_security_group.application) == 3 && length(aws_security_group.data) == 5
    error_message = "환경별 애플리케이션 SG 3개와 데이터 SG 5개가 필요합니다."
  }
}

run "Secret과_namespace는_prod_환경에_격리된다" {
  command = plan

  assert {
    condition     = aws_service_discovery_http_namespace.main.name == "prod.cosmos-v2.local"
    error_message = "기본 namespace는 prod 환경 전용이어야 합니다."
  }

  assert {
    condition = toset([for secret in aws_secretsmanager_secret.service : secret.name]) == toset([
      "/cosmos-v2/prod/spring", "/cosmos-v2/prod/fastapi", "/cosmos-v2/prod/judge-api",
      "/cosmos-v2/prod/ai-postgres", "/cosmos-v2/prod/judge-postgres",
      "/cosmos-v2/prod/judge-redis", "/cosmos-v2/prod/judge-worker",
    ])
    error_message = "서비스별 prod Secret metadata 7개가 필요합니다."
  }
}

run "RDS와_Valkey는_보호_기본값을_사용한다" {
  command = plan

  assert {
    condition = (
      aws_db_instance.mysql.engine == "mysql" &&
      aws_db_instance.mysql.storage_encrypted &&
      !aws_db_instance.mysql.publicly_accessible &&
      aws_db_instance.mysql.deletion_protection &&
      aws_db_instance.mysql.manage_master_user_password
    )
    error_message = "RDS MySQL 보호 설정이 유지되어야 합니다."
  }

  assert {
    condition = (
      aws_elasticache_user.spring.user_id == "cosmos-v2-prod-spring" &&
      aws_elasticache_user.spring.authentication_mode[0].type == "iam" &&
      toset(aws_elasticache_serverless_cache.backend.subnet_ids) == toset(values(var.data_subnet_ids))
    )
    error_message = "Valkey는 환경별 IAM user와 공유 Data subnet을 사용해야 합니다."
  }
}

run "RDS_storage_상한이_초기값보다_작으면_거부한다" {
  command = plan
  variables {
    rds_allocated_storage     = 30
    rds_max_allocated_storage = 20
  }
  expect_failures = [var.rds_max_allocated_storage]
}

