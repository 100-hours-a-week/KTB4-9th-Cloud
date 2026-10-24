mock_provider "aws" {
  override_data {
    target          = data.aws_instances.stage_office_hours_stateful
    override_during = plan
    values          = { ids = ["i-0123456789abcdef0"] }
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
    target = data.aws_iam_policy_document.stage_office_hours_sfn_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.stage_office_hours_sfn
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.stage_office_hours_scheduler_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_iam_policy_document.stage_office_hours_scheduler
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = data.aws_ssm_parameter.ecs_optimized_al2023
    values = { value = "ami-0123456789abcdef0" }
  }

  override_resource {
    target          = aws_s3_bucket.frontend
    override_during = plan
    values = {
      arn = "arn:aws:s3:::cosmos-v2-stage-frontend-123456789012"
    }
  }

  override_resource {
    target          = aws_cloudfront_distribution.frontend
    override_during = plan
    values = {
      arn = "arn:aws:cloudfront::123456789012:distribution/TEST"
    }
  }
}

run "운영시간_자동화는_중지된_stateful_EC2도_조회한다" {
  command = plan

  variables {
    enable_stage_office_hours = true
  }

  assert {
    condition = data.aws_instances.stage_office_hours_stateful[0].instance_state_names == toset([
      "pending",
      "running",
      "stopping",
      "stopped",
    ])
    error_message = "운영시간 자동화는 중지된 Stateful EC2도 조회해야 합니다."
  }
}

variables {
  environment                       = "stage"
  vpc_id                            = "vpc-0123456789abcdef0"
  route53_zone_id                   = "Z0123456789"
  cloudfront_certificate_arn        = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  regional_wildcard_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/regional-test"
  github_oidc_provider_arn          = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"

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

run "Stage_CD는_저장소별_최소권한_role을_사용한다" {
  command = plan

  assert {
    condition     = toset(keys(aws_iam_role.github_stage_cd)) == toset(["fastapi", "spring", "judge", "frontend"])
    error_message = "Stage CD role은 AI, Backend, Judge, Frontend 저장소별로 하나씩 필요합니다."
  }

  assert {
    condition = (
      strcontains(aws_iam_role.github_stage_cd["fastapi"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-AI@1344703221:environment:staging") &&
      strcontains(aws_iam_role.github_stage_cd["spring"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-BE@1344700709:environment:staging") &&
      strcontains(aws_iam_role.github_stage_cd["judge"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-Judge@1374079744:environment:staging") &&
      strcontains(aws_iam_role.github_stage_cd["frontend"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-FE@1344701389:environment:staging")
    )
    error_message = "각 CD role은 immutable 조직/저장소 ID와 staging Environment가 포함된 GitHub OIDC subject만 신뢰해야 합니다."
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.github_stage_container_cd)) == toset(["fastapi", "spring", "judge"])
    error_message = "Container CD policy는 AI, Backend, Judge에 각각 하나씩 필요합니다."
  }

  assert {
    condition     = contains(local.github_stage_target_health_actions, "elasticloadbalancing:DescribeTargetHealth")
    error_message = "Container CD role은 배포 후 ALB target health를 검증할 수 있어야 합니다."
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.github_stage_frontend_cd)) == toset(["frontend"])
    error_message = "Frontend CD policy는 frontend 역할에 하나만 필요합니다."
  }

  assert {
    condition = contains(
      flatten([
        for statement in jsondecode(aws_iam_role_policy.github_stage_frontend_cd["frontend"].policy).Statement :
        statement.Action
      ]),
      "s3:DeleteObject",
    )
    error_message = "Frontend CD role은 aws s3 sync --delete를 위해 s3:DeleteObject 권한이 필요합니다."
  }

  assert {
    condition     = toset(keys(output.github_stage_cd_role_arns)) == toset(["fastapi", "spring", "judge", "frontend"])
    error_message = "Environment output은 네 Stage CD role ARN을 제공해야 합니다."
  }
}

run "ALB_인증서가_서울_리전이_아니면_거부한다" {
  command = plan

  variables {
    regional_wildcard_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  }

  expect_failures = [var.regional_wildcard_certificate_arn]
}
