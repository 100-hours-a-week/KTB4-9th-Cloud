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
    values = { value = "ami-0123456789abcdef0" }
  }
  override_resource {
    target = aws_lb.main
    values = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/cosmos-v2-prod-alb/1234567890abcdef" }
  }
  override_resource {
    target = aws_iam_role.dlm
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-dlm" }
  }
  override_resource {
    target = aws_iam_role.worker_execution
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-judge-worker-execution" }
  }
  override_resource {
    target = aws_iam_role.worker_task
    values = { arn = "arn:aws:iam::123456789012:role/cosmos-v2-prod-judge-worker-task" }
  }
  override_resource {
    target = aws_autoscaling_group.worker_on_demand
    values = { arn = "arn:aws:autoscaling:ap-northeast-2:123456789012:autoScalingGroup:11111111-1111-1111-1111-111111111111:autoScalingGroupName/cosmos-v2-prod-judge-worker-on-demand" }
  }
  override_resource {
    target = aws_autoscaling_group.worker_spot
    values = { arn = "arn:aws:autoscaling:ap-northeast-2:123456789012:autoScalingGroup:22222222-2222-2222-2222-222222222222:autoScalingGroupName/cosmos-v2-prod-judge-worker-spot" }
  }
  override_resource {
    target = aws_ecs_task_definition.judge_worker
    values = { arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/cosmos-v2-prod-judge-worker:1" }
  }

  override_resource {
    target          = aws_secretsmanager_secret.service
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:runtime" }
  }
}

run "Worker_기본값은_비활성_최소_용량이다" {
  command = plan

  assert {
    condition = (
      !var.enable_judge_worker_capacity &&
      !var.enable_judge_worker &&
      var.judge_worker_cpu == 2048 &&
      var.judge_worker_memory == 2048 &&
      var.judge_worker_desired_count == 1 &&
      var.worker_on_demand_instance_type == "c7i.large" &&
      var.worker_spot_instance_types == tolist(["c7i.large", "c6i.large", "c6a.large"]) &&
      var.worker_spot_max_size == 7 &&
      var.worker_root_volume_size == 50
    )
    error_message = "Worker의 비활성 기본값과 task/host 용량이 설계와 일치해야 합니다."
  }

  assert {
    condition     = length(local.enabled_worker_capacity) == 0 && length(local.enabled_judge_worker) == 0
    error_message = "기본 상태에서는 Worker capacity와 Service 조건부 map이 비어 있어야 합니다."
  }

  assert {
    condition     = length(aws_ecs_task_definition.judge_worker) == 0 && length(aws_ecs_service.judge_worker) == 0
    error_message = "기본 상태에서는 Worker Task Definition과 Service를 만들지 않아야 합니다."
  }
}

run "Spot_최대치_범위를_벗어나면_거부한다" {
  command = plan
  variables { worker_spot_max_size = 3 }
  expect_failures = [var.worker_spot_max_size]
}

run "Spot_후보가_비거나_중복되면_거부한다" {
  command = plan
  variables { worker_spot_instance_types = ["c7i.large", "c7i.large"] }
  expect_failures = [var.worker_spot_instance_types]
}

run "Capacity없이_Worker를_활성화하면_거부한다" {
  command = plan
  variables {
    enable_judge_worker = true
    judge_image_digest  = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [check.judge_worker_capacity_enabled]
}

run "잘못된_Worker_digest는_거부한다" {
  command = plan
  variables {
    enable_judge_worker_capacity = true
    enable_judge_worker          = true
    judge_image_digest           = "latest"
  }
  expect_failures = [var.judge_image_digest]
}

run "Worker_Judge_공용_ECR_Secret_Log_metadata를_구성한다" {
  command = plan

  assert {
    condition = (
      output.judge_ecr_repository_url == var.ecr_repository_urls["judge"] &&
      output.judge_ecr_repository_arn == var.ecr_repository_arns["judge"]
    )
    error_message = "Worker는 공유 계층에서 전달받은 ECR을 사용해야 합니다."
  }

  assert {
    condition = (
      aws_secretsmanager_secret.service["judge-worker"].name == "/cosmos-v2/prod/judge-worker" &&
      aws_cloudwatch_log_group.worker.name == "/ecs/cosmos-v2-prod/judge-worker" &&
      aws_cloudwatch_log_group.worker.retention_in_days == 30
    )
    error_message = "Worker Secret metadata와 Log Group이 naming/retention 계약을 따라야 합니다."
  }
}

run "Worker_Task와_host_네트워크를_분리한다" {
  command = plan

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.worker_postgres.from_port == 5432 &&
      aws_vpc_security_group_egress_rule.worker_redis.from_port == 6379 &&
      length(aws_vpc_security_group_egress_rule.worker_dns) == 2 &&
      alltrue([for rule in aws_vpc_security_group_egress_rule.worker_dns : rule.cidr_ipv4 == "10.20.0.2/32" && rule.from_port == 53 && rule.to_port == 53])
    )
    error_message = "Worker Task는 PostgreSQL, Redis, VPC DNS egress만 가져야 합니다."
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.worker_host_https.cidr_ipv4 == "0.0.0.0/0" &&
      aws_vpc_security_group_egress_rule.worker_host_https.from_port == 443 &&
      length(aws_vpc_security_group_egress_rule.worker_host_dns) == 2 &&
      aws_vpc_security_group_ingress_rule.judge_postgres_from_worker.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.judge_redis_from_worker.from_port == 6379
    )
    error_message = "Worker host AWS 통신과 DB/Redis의 Worker source ingress가 필요합니다."
  }
}

run "Worker_IAM은_세_Secret만_읽는다" {
  command = plan

  assert {
    condition = (
      aws_iam_role_policy_attachment.worker_execution.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" &&
      local.worker_secret_access == ["judge-api", "judge-postgres", "judge-redis"] &&
      aws_iam_role_policy.worker_secrets.name == "read-worker-runtime-secrets"
    )
    error_message = "Worker execution role은 task execution policy와 세 Secret 조회 권한만 가져야 합니다."
  }

  assert {
    condition     = aws_iam_role.worker_task.name == "cosmos-v2-prod-judge-worker-task"
    error_message = "Worker task role은 별도 정책 없는 전용 role이어야 합니다."
  }
}

run "Worker_capacity가_꺼지면_EC2_용량을_만들지_않는다" {
  command = plan

  assert {
    condition = (
      length(aws_iam_role.worker_instance) == 0 &&
      length(aws_iam_instance_profile.worker) == 0 &&
      length(aws_launch_template.worker) == 0 &&
      length(aws_autoscaling_group.worker_on_demand) == 0 &&
      length(aws_autoscaling_group.worker_spot) == 0 &&
      length(aws_ecs_capacity_provider.worker_on_demand) == 0 &&
      length(aws_ecs_capacity_provider.worker_spot) == 0 &&
      aws_ecs_cluster_capacity_providers.main.capacity_providers == toset(["FARGATE"])
    )
    error_message = "Worker capacity 비활성 상태에서는 EC2 관련 리소스가 없어야 합니다."
  }
}

run "Worker_capacity_provider를_cluster에_연결한다" {
  command = plan

  variables { enable_judge_worker_capacity = true }

  assert {
    condition = (
      length(aws_ecs_capacity_provider.worker_on_demand) == 1 &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_draining == "ENABLED" &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_termination_protection == "ENABLED" &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_scaling[0].status == "ENABLED" &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_scaling[0].target_capacity == 100 &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_scaling[0].minimum_scaling_step_size == 1 &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_scaling[0].maximum_scaling_step_size == 1 &&
      aws_ecs_capacity_provider.worker_on_demand[0].auto_scaling_group_provider[0].managed_scaling[0].instance_warmup_period == 300
    )
    error_message = "On-Demand Capacity Provider는 보호된 managed scaling 1대 계약을 따라야 합니다."
  }

  assert {
    condition = (
      length(aws_ecs_capacity_provider.worker_spot) == 1 &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_draining == "ENABLED" &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_termination_protection == "ENABLED" &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_scaling[0].status == "ENABLED" &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_scaling[0].target_capacity == 100 &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_scaling[0].minimum_scaling_step_size == 1 &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_scaling[0].maximum_scaling_step_size == 7 &&
      aws_ecs_capacity_provider.worker_spot[0].auto_scaling_group_provider[0].managed_scaling[0].instance_warmup_period == 300
    )
    error_message = "Spot Capacity Provider는 보호된 managed scaling 0~7대 계약을 따라야 합니다."
  }

  assert {
    condition = (
      aws_ecs_cluster_capacity_providers.main.capacity_providers == toset([
        "FARGATE",
        "cosmos-v2-prod-judge-worker-on-demand",
        "cosmos-v2-prod-judge-worker-spot",
      ]) &&
      length(aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy) == 1 &&
      one(aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy).capacity_provider == "FARGATE"
    )
    error_message = "Cluster에는 Worker provider를 추가하되 기본 전략은 FARGATE로 유지해야 합니다."
  }
}

run "Worker_OnDemand와_Spot_ASG를_분리한다" {
  command = plan

  variables { enable_judge_worker_capacity = true }

  assert {
    condition = (
      length(aws_iam_role.worker_instance) == 1 &&
      length(aws_iam_instance_profile.worker) == 1 &&
      length(aws_iam_role_policy_attachment.worker_instance) == 2 &&
      toset([for attachment in aws_iam_role_policy_attachment.worker_instance : attachment.policy_arn]) == toset([
        "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
      ])
    )
    error_message = "Worker instance role에는 ECS container instance와 SSM 정책만 필요합니다."
  }

  assert {
    condition = (
      length(aws_launch_template.worker) == 1 &&
      aws_launch_template.worker[0].image_id == "ami-0123456789abcdef0" &&
      aws_launch_template.worker[0].key_name == null &&
      aws_launch_template.worker[0].network_interfaces[0].associate_public_ip_address == "false" &&
      aws_launch_template.worker[0].metadata_options[0].http_tokens == "required" &&
      aws_launch_template.worker[0].monitoring[0].enabled &&
      aws_launch_template.worker[0].block_device_mappings[0].ebs[0].encrypted == "true" &&
      aws_launch_template.worker[0].block_device_mappings[0].ebs[0].volume_type == "gp3" &&
      aws_launch_template.worker[0].block_device_mappings[0].ebs[0].volume_size == 50 &&
      aws_launch_template.worker[0].block_device_mappings[0].ebs[0].delete_on_termination == "true"
    )
    error_message = "Worker Launch Template은 private, IMDSv2, encrypted gp3 계약을 따라야 합니다."
  }

  assert {
    condition = (
      strcontains(base64decode(aws_launch_template.worker[0].user_data), "ECS_CLUSTER=cosmos-v2-prod-cluster") &&
      strcontains(base64decode(aws_launch_template.worker[0].user_data), "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true") &&
      strcontains(base64decode(aws_launch_template.worker[0].user_data), "ECS_ENABLE_CONTAINER_METADATA=true") &&
      strcontains(base64decode(aws_launch_template.worker[0].user_data), "systemctl enable ecs") &&
      !strcontains(base64decode(aws_launch_template.worker[0].user_data), "systemctl enable --now ecs")
    )
    error_message = "Worker host는 ECS 설정 후 cloud-final 교착 없이 ECS를 활성화해야 합니다."
  }

  assert {
    condition = (
      aws_autoscaling_group.worker_on_demand[0].min_size == 1 &&
      aws_autoscaling_group.worker_on_demand[0].desired_capacity == 1 &&
      aws_autoscaling_group.worker_on_demand[0].max_size == 1 &&
      aws_autoscaling_group.worker_on_demand[0].protect_from_scale_in &&
      length(aws_autoscaling_group.worker_on_demand[0].vpc_zone_identifier) == 2 &&
      one([for tag in aws_autoscaling_group.worker_on_demand[0].tag : tag.value if tag.key == "AmazonECSManaged"]) == "" &&
      aws_autoscaling_group.worker_on_demand[0].mixed_instances_policy[0].launch_template[0].override[0].instance_type == "c7i.large"
    )
    error_message = "On-Demand ASG는 c7i.large 한 대를 private subnet에 유지해야 합니다."
  }

  assert {
    condition = (
      aws_autoscaling_group.worker_spot[0].min_size == 0 &&
      aws_autoscaling_group.worker_spot[0].desired_capacity == 0 &&
      aws_autoscaling_group.worker_spot[0].max_size == 7 &&
      aws_autoscaling_group.worker_spot[0].protect_from_scale_in &&
      aws_autoscaling_group.worker_spot[0].capacity_rebalance &&
      one([for tag in aws_autoscaling_group.worker_spot[0].tag : tag.value if tag.key == "AmazonECSManaged"]) == "" &&
      aws_autoscaling_group.worker_spot[0].mixed_instances_policy[0].instances_distribution[0].on_demand_percentage_above_base_capacity == 0 &&
      aws_autoscaling_group.worker_spot[0].mixed_instances_policy[0].instances_distribution[0].spot_allocation_strategy == "capacity-optimized-prioritized" &&
      toset([for override in aws_autoscaling_group.worker_spot[0].mixed_instances_policy[0].launch_template[0].override : override.instance_type]) == toset(["c7i.large", "c6i.large", "c6a.large"])
    )
    error_message = "Spot ASG는 0~7대와 세 후보, capacity-optimized-prioritized 계약을 따라야 합니다."
  }
}

run "Judge_Worker_Task와_Service를_격리한다" {
  command = plan

  variables {
    enable_judge_worker_capacity = true
    enable_judge_worker          = true
    judge_image_digest           = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition = (
      aws_ecs_task_definition.judge_worker["worker"].family == "cosmos-v2-prod-judge-worker" &&
      aws_ecs_task_definition.judge_worker["worker"].requires_compatibilities == toset(["EC2"]) &&
      aws_ecs_task_definition.judge_worker["worker"].network_mode == "awsvpc" &&
      aws_ecs_task_definition.judge_worker["worker"].cpu == "2048" &&
      aws_ecs_task_definition.judge_worker["worker"].memory == "2048" &&
      one(aws_ecs_task_definition.judge_worker["worker"].runtime_platform).cpu_architecture == "X86_64" &&
      one(aws_ecs_task_definition.judge_worker["worker"].runtime_platform).operating_system_family == "LINUX"
    )
    error_message = "Worker Task Definition은 EC2/awsvpc/Linux X86_64와 2 vCPU/2GiB 계약을 따라야 합니다."
  }

  assert {
    condition = (
      local.enabled_judge_worker.worker.image_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &&
      var.ecr_repository_urls["judge"] == "ecr/judge" &&
      local.enabled_judge_worker.worker.cpu == 2048 &&
      local.enabled_judge_worker.worker.memory == 2048
    )
    error_message = "Worker는 공유 ECR digest와 2 vCPU/2GiB task 계약을 사용해야 합니다."
  }

  assert {
    condition = (
      local.worker_container_image == "ecr/judge@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &&
      local.worker_container_command == tolist(["./scripts/workers"])
    )
    error_message = "Judge Worker는 공용 judge image와 workers 실행 명령을 사용해야 합니다."
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.judge_worker["worker"].container_definitions)[0].privileged &&
      !jsondecode(aws_ecs_task_definition.judge_worker["worker"].container_definitions)[0].readonlyRootFilesystem &&
      !contains(keys(jsondecode(aws_ecs_task_definition.judge_worker["worker"].container_definitions)[0]), "healthCheck") &&
      { for item in local.worker_environment : item.name => item.value } == {
        POSTGRES_HOST    = "judge-postgres"
        POSTGRES_PORT    = "5432"
        REDIS_HOST       = "judge-redis"
        REDIS_PORT       = "6379"
        RAILS_ENV        = "production"
        RESQUE_NAMESPACE = "prod:judge0"
        COUNT            = "2"
        INTERVAL         = "0.1"
      } &&
      toset([for secret in local.worker_secrets : secret.name]) == toset([
        "SECRET_KEY_BASE", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "REDIS_PASSWORD",
      ]) &&
      one([for secret in local.worker_secrets : secret.valueFrom if secret.name == "SECRET_KEY_BASE"]) == "${aws_secretsmanager_secret.service["judge-api"].arn}:secret_key_base::" &&
      !contains([for secret in local.worker_secrets : secret.name], "JUDGE_WORKER_SECRET_JSON")
    )
    error_message = "Judge Worker는 writable privileged root, 실제 환경 변수별 Secret, COUNT/INTERVAL을 사용하고 무효 health check를 포함하지 않아야 합니다."
  }

  assert {
    condition = (
      aws_ecs_service.judge_worker["worker"].desired_count == 1 &&
      aws_ecs_service.judge_worker["worker"].deployment_minimum_healthy_percent == 0 &&
      aws_ecs_service.judge_worker["worker"].deployment_maximum_percent == 100 &&
      !aws_ecs_service.judge_worker["worker"].enable_execute_command &&
      one(aws_ecs_service.judge_worker["worker"].deployment_circuit_breaker).enable &&
      one(aws_ecs_service.judge_worker["worker"].deployment_circuit_breaker).rollback &&
      length(aws_ecs_service.judge_worker["worker"].load_balancer) == 0 &&
      length(aws_ecs_service.judge_worker["worker"].placement_constraints) == 1 &&
      one(aws_ecs_service.judge_worker["worker"].placement_constraints).type == "distinctInstance"
    )
    error_message = "Worker Service는 stop-before-start, rollback, no Exec/ALB, distinctInstance 계약을 따라야 합니다."
  }

  assert {
    condition = (
      length(one(aws_ecs_service.judge_worker["worker"].network_configuration).subnets) == 2 &&
      one(aws_ecs_service.judge_worker["worker"].network_configuration).assign_public_ip == false &&
      one(aws_ecs_service.judge_worker["worker"].service_connect_configuration).enabled &&
      length(one(aws_ecs_service.judge_worker["worker"].service_connect_configuration).service) == 0
    )
    error_message = "Worker Service는 private network와 client-only Service Connect를 사용해야 합니다."
  }

  assert {
    condition = (
      length(aws_ecs_service.judge_worker["worker"].capacity_provider_strategy) == 2 &&
      anytrue([for strategy in aws_ecs_service.judge_worker["worker"].capacity_provider_strategy : strategy.capacity_provider == "cosmos-v2-prod-judge-worker-on-demand" && strategy.base == 1 && strategy.weight == 0]) &&
      anytrue([for strategy in aws_ecs_service.judge_worker["worker"].capacity_provider_strategy : strategy.capacity_provider == "cosmos-v2-prod-judge-worker-spot" && strategy.base == 0 && strategy.weight == 1])
    )
    error_message = "첫 Worker는 On-Demand, 추가 Worker는 Spot에 배치해야 합니다."
  }
}

run "Worker_desired가_capacity를_넘으면_거부한다" {
  command = plan

  variables {
    enable_judge_worker_capacity = true
    enable_judge_worker          = true
    judge_image_digest           = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    judge_worker_desired_count   = 8
    worker_spot_max_size         = 4
  }

  expect_failures = [aws_ecs_service.judge_worker["worker"]]
}

run "Worker_output은_비민감_식별자만_제공한다" {
  command = plan

  assert {
    condition = (
      output.judge_ecr_repository_url == var.ecr_repository_urls["judge"] &&
      output.judge_ecr_repository_arn == var.ecr_repository_arns["judge"] &&
      output.worker_log_group_name == aws_cloudwatch_log_group.worker.name
    )
    error_message = "Worker 공통 output은 ECR, Secret metadata, SG, Log 식별자를 제공해야 합니다."
  }

  assert {
    condition = (
      length(output.worker_autoscaling_group_names) == 0 &&
      length(output.worker_autoscaling_group_arns) == 0 &&
      length(output.worker_capacity_provider_names) == 0 &&
      output.worker_task_definition_arn == null &&
      output.worker_ecs_service_name == null
    )
    error_message = "Worker 비활성 상태의 조건부 output은 빈 map 또는 null이어야 합니다."
  }
}

run "Worker_capacity와_service_output을_제공한다" {
  command = plan

  variables {
    enable_judge_worker_capacity = true
    enable_judge_worker          = true
    judge_image_digest           = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition = (
      length(output.worker_autoscaling_group_names) == 2 &&
      length(output.worker_autoscaling_group_arns) == 2 &&
      output.worker_capacity_provider_names.on_demand == "cosmos-v2-prod-judge-worker-on-demand" &&
      output.worker_capacity_provider_names.spot == "cosmos-v2-prod-judge-worker-spot" &&
      output.worker_ecs_service_name == "cosmos-v2-prod-judge-worker"
    )
    error_message = "Worker 활성 상태의 ASG, Capacity Provider, Task, Service output이 필요합니다."
  }
}
