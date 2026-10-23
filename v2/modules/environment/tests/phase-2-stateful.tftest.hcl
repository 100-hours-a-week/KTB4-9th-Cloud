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
    target = data.aws_ssm_parameter.ecs_optimized_al2023
    values = { value = "ami-0123456789abcdef0" }
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

  override_resource {
    target = aws_lb.main
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/cosmos-v2-prod-alb/1234567890abcdef" }
  }

  override_resource {
    target = aws_iam_role.stateful_execution
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-stateful-execution" }
  }

  override_resource {
    target = aws_iam_role.stateful_task
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-stateful-task" }
  }

  override_resource {
    target = aws_iam_role.dlm
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-dlm" }
  }

  override_resource {
    target          = aws_secretsmanager_secret.service
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:runtime" }
  }
}

run "상태_저장_기반은_공유_한_대와_단일_보존_EBS를_사용한다" {
  command = plan

  assert {
    condition = (
      var.stateful_instance_type == "t3.medium" &&
      var.stateful_ebs_size == 30 &&
      !var.enable_stateful_services &&
      length(local.stateful_services) == 3 &&
      aws_ebs_volume.stateful.size == 30 &&
      aws_volume_attachment.stateful.device_name == "/dev/sdf"
    )
    error_message = "AI PostgreSQL, Judge PostgreSQL, Redis는 t3.medium 1대와 단일 30GiB EBS를 공유해야 합니다."
  }

  assert {
    condition = (
      try(
        local.stateful_services["ai-postgres"].index == "0" &&
        local.stateful_services["ai-postgres"].port == 5432 &&
        local.stateful_services["ai-postgres"].mount_path == "/var/lib/postgresql/data" &&
        local.stateful_services["ai-postgres"].host_mount_path == "/srv/cosmos/ai-postgres" &&
        local.stateful_services["ai-postgres"].backup_retention == 7,
        false,
      ) &&
      local.stateful_services["judge-postgres"].index == "0" &&
      local.stateful_services["judge-postgres"].port == 5432 &&
      local.stateful_services["judge-postgres"].backup_retention == 7 &&
      local.stateful_services["judge-redis"].index == "0" &&
      local.stateful_services["judge-redis"].port == 6379 &&
      local.stateful_services["judge-redis"].backup_retention == 3
    )
    error_message = "상태 저장 서비스의 AZ, port, snapshot 보존 계약이 일치해야 합니다."
  }

  assert {
    condition = (
      !aws_instance.stateful.associate_public_ip_address &&
      aws_instance.stateful.metadata_options[0].http_tokens == "required" &&
      aws_instance.stateful.root_block_device[0].encrypted
    )
    error_message = "상태 저장 EC2는 public IP 없이 IMDSv2와 암호화 root volume을 사용해야 합니다."
  }

  assert {
    condition     = length(aws_ecs_task_definition.stateful) == 0 && length(aws_ecs_service.stateful) == 0
    error_message = "기본 bootstrap에서는 상태 저장 Task/Service를 만들지 않아야 합니다."
  }
}

run "작은_EBS는_거부한다" {
  command = plan
  variables { stateful_ebs_size = 10 }
  expect_failures = [var.stateful_ebs_size]
}

run "digest없이_상태_저장_서비스를_활성화하면_거부한다" {
  command = plan
  variables { enable_stateful_services = true }
  expect_failures = [var.ai_postgres_image, var.judge_postgres_image, var.judge_redis_image]
}

run "tag_only_AI_PostgreSQL_image는_거부한다" {
  command = plan
  variables {
    enable_stateful_services = true
    ai_postgres_image        = "pgvector/pgvector:pg17"
    judge_postgres_image     = "public.ecr.aws/docker/library/postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    judge_redis_image        = "public.ecr.aws/valkey/valkey@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [var.ai_postgres_image]
}

run "대문자_digest_AI_PostgreSQL_image는_거부한다" {
  command = plan
  variables {
    enable_stateful_services = true
    ai_postgres_image        = "pgvector/pgvector:pg17@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    judge_postgres_image     = "public.ecr.aws/docker/library/postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    judge_redis_image        = "public.ecr.aws/valkey/valkey@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [var.ai_postgres_image]
}

run "상태_저장_Task와_Service는_고정_호스트와_Service_Connect를_사용한다" {
  command = plan

  variables {
    enable_stateful_services = true
    ai_postgres_image        = "pgvector/pgvector:pg17@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    judge_postgres_image     = "public.ecr.aws/docker/library/postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    judge_redis_image        = "public.ecr.aws/valkey/valkey@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }

  assert {
    condition     = length(aws_ecs_task_definition.stateful) == 2 && length(aws_ecs_service.stateful) == 2
    error_message = "활성화 시 AI PostgreSQL Task/Service와 Judge PostgreSQL·Redis 통합 Task/Service가 생성되어야 합니다."
  }

  assert {
    condition = alltrue([
      for key, task in aws_ecs_task_definition.stateful :
      task.network_mode == "awsvpc" &&
      task.requires_compatibilities == toset(["EC2"]) &&
      length(task.volume) == length(local.stateful_task_groups[key].service_keys) &&
      alltrue([
        for volume in task.volume : contains([
          for service_key in local.stateful_task_groups[key].service_keys :
          local.stateful_services[service_key].host_mount_path
        ], volume.host_path)
      ]) &&
      jsondecode(task.container_definitions)[0].memoryReservation == local.stateful_services[key].memory_reservation &&
      !jsondecode(task.container_definitions)[0].readonlyRootFilesystem &&
      can(regex("@sha256:[0-9a-f]{64}$", local.stateful_services[key].image))
    ])
    error_message = "상태 저장 Task는 EC2/awsvpc, 공식 immutable image, host volume과 writable root를 사용해야 합니다."
  }

  assert {
    condition = (
      jsondecode(local.stateful_container_definitions["ai-postgres"])[0].image == var.ai_postgres_image &&
      toset([
        for item in jsondecode(local.stateful_container_definitions["ai-postgres"])[0].environment :
        "${item.name}|${item.value}"
        ]) == toset([
        "POSTGRES_DB|cosmos",
        "PGDATA|/var/lib/postgresql/data/pgdata",
      ]) &&
      toset([
        for secret in jsondecode(local.stateful_container_definitions["ai-postgres"])[0].secrets :
        "${secret.name}|${secret.valueFrom}"
        ]) == toset([
        "POSTGRES_USER|${aws_secretsmanager_secret.service["ai-postgres"].arn}:username::",
        "POSTGRES_PASSWORD|${aws_secretsmanager_secret.service["ai-postgres"].arn}:password::",
      ]) &&
      one(jsondecode(local.stateful_container_definitions["ai-postgres"])[0].mountPoints).containerPath == "/var/lib/postgresql/data" &&
      jsondecode(local.stateful_container_definitions["ai-postgres"])[0].healthCheck.command == [
        "CMD-SHELL", "pg_isready -U $POSTGRES_USER -d cosmos || exit 1",
      ]
    )
    error_message = "AI PostgreSQL은 cosmos DB, 전용 username/password Secret, pgvector image와 persistent data mount를 사용해야 합니다."
  }

  assert {
    condition = (
      !aws_instance.stateful.associate_public_ip_address &&
      !aws_ecs_service.stateful["ai-postgres"].network_configuration[0].assign_public_ip &&
      !contains(keys(aws_lb_target_group.stage_service), "ai-postgres")
    )
    error_message = "AI PostgreSQL은 public IP와 ALB target group 없이 내부에서만 실행되어야 합니다."
  }

  assert {
    condition = (
      one([
        for container in jsondecode(local.stateful_container_definitions["judge-postgres"]) : container
        if container.name == "judge-redis"
        ]).command == [
        "sh", "-c", "exec redis-server --appendonly yes --requirepass \"$REDIS_PASSWORD\"",
      ] &&
      one([
        for container in jsondecode(local.stateful_container_definitions["judge-postgres"]) : container
        if container.name == "judge-redis"
        ]).healthCheck.command == [
        "CMD-SHELL", "redis-cli -a $REDIS_PASSWORD ping | grep PONG",
      ]
    )
    error_message = "Judge Redis 7.2.4 image는 redis-server와 redis-cli 명령을 사용해야 합니다."
  }

  assert {
    condition = alltrue([
      for key, service in aws_ecs_service.stateful :
      service.desired_count == 1 &&
      service.launch_type == "EC2" &&
      service.deployment_minimum_healthy_percent == 0 &&
      service.deployment_maximum_percent == 100 &&
      !service.network_configuration[0].assign_public_ip &&
      one(service.placement_constraints).expression == "attribute:stateful == true" &&
      toset([
        for endpoint in service.service_connect_configuration[0].service :
        endpoint.client_alias[0].dns_name
      ]) == toset(local.stateful_task_groups[key].service_keys)
    ])
    error_message = "상태 저장 Service는 단일 고정 호스트, stop-before-start, Service Connect를 사용해야 합니다."
  }
}

run "DLM은_통합_EBS의_일일_snapshot을_보존한다" {
  command = plan

  assert {
    condition = (
      aws_dlm_lifecycle_policy.stateful.state == "ENABLED" &&
      aws_dlm_lifecycle_policy.stateful.policy_details[0].target_tags.BackupPolicy == "stateful" &&
      aws_dlm_lifecycle_policy.stateful.policy_details[0].schedule[0].create_rule[0].interval == 24 &&
      aws_dlm_lifecycle_policy.stateful.policy_details[0].schedule[0].retain_rule[0].count == 7
    )
    error_message = "통합 EBS는 일일 snapshot 7개를 보존해야 합니다."
  }
}

