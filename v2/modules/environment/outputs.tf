output "ecs_cluster_name" {
  description = "ECS Cluster 이름"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS Cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "ecr_repository_urls" {
  description = "공유 계층에서 전달받은 서비스별 ECR repository URL"
  value       = var.ecr_repository_urls
}

output "ecr_repository_arns" {
  description = "공유 계층에서 전달받은 서비스별 ECR repository ARN"
  value       = var.ecr_repository_arns
}

output "github_stage_cd_role_arns" {
  description = "저장소별 GitHub Stage CD role ARN"
  value       = { for key, role in aws_iam_role.github_stage_cd : key => role.arn }
}

output "alb_arn" {
  description = "Application Load Balancer ARN"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS 이름"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Application Load Balancer Route 53 zone ID"
  value       = aws_lb.main.zone_id
}

output "frontend_bucket_name" {
  description = "환경별 private frontend S3 bucket 이름"
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "환경별 CloudFront distribution ID"
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_distribution_arn" {
  description = "환경별 CloudFront distribution ARN"
  value       = aws_cloudfront_distribution.frontend.arn
}

output "cloudfront_domain_name" {
  description = "환경별 CloudFront 기본 domain"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "frontend_url" {
  description = "사용자가 접근할 환경별 frontend URL"
  value       = var.enable_public_dns_cutover ? "https://${var.domain_name}" : (var.environment == "stage" ? "https://stage.${var.domain_name}" : "https://${aws_cloudfront_distribution.frontend.domain_name}")
}

output "stage_service_urls" {
  description = "Stage에서 공개하는 애플리케이션 서비스별 HTTPS URL"
  value       = local.stage_service_urls
}

output "alb_security_group_id" {
  description = "Application Load Balancer Security Group ID"
  value       = aws_security_group.alb.id
}

output "ecs_task_execution_role_arn" {
  description = "공통 ECS task execution role ARN"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "cloudwatch_log_group_names" {
  description = "서비스별 CloudWatch Log Group 이름"
  value       = { for key, log_group in aws_cloudwatch_log_group.service : key => log_group.name }
}

output "service_connect_namespace_arn" {
  description = "Service Connect HTTP namespace ARN"
  value       = aws_service_discovery_http_namespace.main.arn
}

output "service_secret_arns" {
  description = "서비스별 Secrets Manager metadata ARN"
  value       = { for key, secret in aws_secretsmanager_secret.service : key => secret.arn }
}

output "rds_mysql_endpoint" {
  description = "RDS MySQL endpoint"
  value       = aws_db_instance.mysql.address
}

output "rds_mysql_port" {
  description = "RDS MySQL port"
  value       = aws_db_instance.mysql.port
}

output "rds_master_secret_arn" {
  description = "RDS-managed master Secret ARN"
  value       = try(aws_db_instance.mysql.master_user_secret[0].secret_arn, null)
}

output "backend_valkey_endpoint" {
  description = "Backend Valkey endpoint"
  value       = try(aws_elasticache_serverless_cache.backend.endpoint[0].address, null)
}

output "backend_valkey_port" {
  description = "Backend Valkey port"
  value       = try(aws_elasticache_serverless_cache.backend.endpoint[0].port, null)
}

output "backend_valkey_arn" {
  description = "Backend Valkey ARN"
  value       = aws_elasticache_serverless_cache.backend.arn
}

output "stateful_image_references" {
  description = "Judge 상태 저장 서비스의 digest 고정 공식 image reference"
  value = {
    judge-postgres = var.judge_postgres_image
    judge-redis    = var.judge_redis_image
  }
}

output "stateful_instance_ids" {
  description = "AI PostgreSQL, Judge PostgreSQL, Redis가 공유하는 상태 저장 EC2 ID"
  value       = { for key in keys(local.stateful_services) : key => aws_instance.stateful.id }
}

output "stateful_ebs_volume_ids" {
  description = "AI PostgreSQL, Judge PostgreSQL, Redis가 공유하는 EBS volume ID"
  value       = { for key in keys(local.stateful_services) : key => aws_ebs_volume.stateful.id }
}

output "stateful_ecs_service_names" {
  description = "활성화된 Judge 상태 저장 ECS Service 이름"
  value = {
    for service_key in keys(local.enabled_stateful_services) : service_key =>
    aws_ecs_service.stateful[service_key == "judge-redis" ? "judge-postgres" : service_key].name
  }
}

output "application_task_definition_arns" {
  description = "활성화된 애플리케이션 Task Definition ARN"
  value       = { for key, task in aws_ecs_task_definition.application : key => task.arn }
}

output "application_ecs_service_names" {
  description = "활성화된 애플리케이션 ECS Service 이름"
  value       = { for key, service in aws_ecs_service.application : key => service.name }
}

output "application_execution_role_arns" {
  description = "애플리케이션별 execution role ARN"
  value       = { for key, role in aws_iam_role.application_execution : key => role.arn }
}

output "application_task_role_arns" {
  description = "애플리케이션별 task role ARN"
  value       = { for key, role in aws_iam_role.application_task : key => role.arn }
}

output "spring_target_group_arn" {
  description = "Spring 전용 ALB Target Group ARN"
  value       = aws_lb_target_group.spring.arn
}

output "judge_ecr_repository_url" {
  description = "Judge API와 Worker가 공유하는 ECR repository URL"
  value       = var.ecr_repository_urls["judge"]
}

output "judge_ecr_repository_arn" {
  description = "Judge API와 Worker가 공유하는 ECR repository ARN"
  value       = var.ecr_repository_arns["judge"]
}

output "worker_secret_arn" {
  description = "Judge Worker Secrets Manager metadata ARN"
  value       = aws_secretsmanager_secret.service["judge-worker"].arn
}

output "worker_task_security_group_id" {
  description = "Judge Worker Task Security Group ID"
  value       = aws_security_group.worker_task.id
}

output "worker_host_security_group_id" {
  description = "Judge Worker host Security Group ID"
  value       = aws_security_group.worker_host.id
}

output "worker_log_group_name" {
  description = "Judge Worker CloudWatch Log Group 이름"
  value       = aws_cloudwatch_log_group.worker.name
}

output "worker_autoscaling_group_names" {
  description = "활성화된 Judge Worker On-Demand/Spot ASG 이름"
  value = merge(
    length(aws_autoscaling_group.worker_on_demand) > 0 ? { on_demand = aws_autoscaling_group.worker_on_demand[0].name } : {},
    length(aws_autoscaling_group.worker_spot) > 0 ? { spot = aws_autoscaling_group.worker_spot[0].name } : {},
  )
}

output "worker_autoscaling_group_arns" {
  description = "활성화된 Judge Worker On-Demand/Spot ASG ARN"
  value = merge(
    length(aws_autoscaling_group.worker_on_demand) > 0 ? { on_demand = aws_autoscaling_group.worker_on_demand[0].arn } : {},
    length(aws_autoscaling_group.worker_spot) > 0 ? { spot = aws_autoscaling_group.worker_spot[0].arn } : {},
  )
}

output "worker_capacity_provider_names" {
  description = "활성화된 Judge Worker On-Demand/Spot Capacity Provider 이름"
  value = merge(
    length(aws_ecs_capacity_provider.worker_on_demand) > 0 ? { on_demand = aws_ecs_capacity_provider.worker_on_demand[0].name } : {},
    length(aws_ecs_capacity_provider.worker_spot) > 0 ? { spot = aws_ecs_capacity_provider.worker_spot[0].name } : {},
  )
}

output "worker_task_definition_arn" {
  description = "활성화된 Judge Worker Task Definition ARN"
  value       = try(aws_ecs_task_definition.judge_worker["worker"].arn, null)
}

output "worker_ecs_service_name" {
  description = "활성화된 Judge Worker ECS Service 이름"
  value       = try(aws_ecs_service.judge_worker["worker"].name, null)
}
