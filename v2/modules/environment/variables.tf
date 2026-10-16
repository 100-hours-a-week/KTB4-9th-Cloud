variable "aws_region" {
  description = "AWS region for the v2 infrastructure"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "aws_region must be ap-northeast-2 for the v2 environment."
  }
}

variable "project_name" {
  description = "Project name used as the resource name prefix"
  type        = string
  default     = "cosmos-v2"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["stage", "prod"], var.environment)
    error_message = "environment must be stage or prod."
  }
}

variable "vpc_id" {
  description = "Shared VPC ID"
  type        = string

  validation {
    condition     = length(trimspace(var.vpc_id)) > 0
    error_message = "vpc_id must not be empty."
  }
}

variable "vpc_cidr" {
  description = "Shared VPC CIDR used to restrict VPC DNS egress"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_ids" {
  description = "Shared Public subnet ID map keyed by 0 and 1"
  type        = map(string)

  validation {
    condition     = toset(keys(var.public_subnet_ids)) == toset(["0", "1"])
    error_message = "public_subnet_ids must contain keys 0 and 1."
  }
}

variable "private_subnet_ids" {
  description = "Shared Private subnet ID map keyed by 0 and 1"
  type        = map(string)

  validation {
    condition     = toset(keys(var.private_subnet_ids)) == toset(["0", "1"])
    error_message = "private_subnet_ids must contain keys 0 and 1."
  }
}

variable "data_subnet_ids" {
  description = "Shared Data subnet ID map keyed by 0 and 1"
  type        = map(string)

  validation {
    condition     = toset(keys(var.data_subnet_ids)) == toset(["0", "1"])
    error_message = "data_subnet_ids must contain keys 0 and 1."
  }
}

variable "ecr_repository_urls" {
  description = "Shared ECR repository URL map"
  type        = map(string)

  validation {
    condition     = toset(keys(var.ecr_repository_urls)) == toset(["spring", "fastapi", "judge"])
    error_message = "ecr_repository_urls must contain spring, fastapi, and judge."
  }
}

variable "ecr_repository_arns" {
  description = "Shared ECR repository ARN map"
  type        = map(string)

  validation {
    condition     = toset(keys(var.ecr_repository_arns)) == toset(["spring", "fastapi", "judge"])
    error_message = "ecr_repository_arns must contain spring, fastapi, and judge."
  }
}

variable "github_oidc_provider_arn" {
  description = "Shared GitHub Actions OIDC provider ARN used by stage CD roles"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.environment != "stage" || can(regex(
      "^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$",
      coalesce(var.github_oidc_provider_arn, ""),
    ))
    error_message = "github_oidc_provider_arn must be the shared GitHub Actions OIDC provider ARN for stage."
  }
}

variable "route53_zone_id" {
  description = "Existing cosmoscode.site public hosted zone ID"
  type        = string

  validation {
    condition     = length(trimspace(var.route53_zone_id)) > 0
    error_message = "route53_zone_id must not be empty."
  }
}

variable "cloudfront_certificate_arn" {
  description = "Existing CloudFront ACM certificate ARN in us-east-1"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.cloudfront_certificate_arn))
    error_message = "cloudfront_certificate_arn must be a us-east-1 ACM certificate ARN."
  }
}

variable "regional_wildcard_certificate_arn" {
  description = "ALB wildcard ACM certificate ARN in ap-northeast-2"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:ap-northeast-2:[0-9]{12}:certificate/", var.regional_wildcard_certificate_arn))
    error_message = "regional_wildcard_certificate_arn must be an ap-northeast-2 ACM certificate ARN."
  }
}

variable "domain_name" {
  description = "Public application domain"
  type        = string
  default     = "cosmoscode.site"

  validation {
    condition     = var.domain_name == "cosmoscode.site"
    error_message = "domain_name must be cosmoscode.site."
  }
}

variable "enable_public_dns_cutover" {
  description = "Allow prod apex and www aliases to move to the v2 CloudFront distribution"
  type        = bool
  default     = false
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch Logs retention period"
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180,
      365, 400, 545, 731, 1096, 1827, 2192, 2557,
      2922, 3288, 3653,
    ], var.cloudwatch_log_retention_days)
    error_message = "cloudwatch_log_retention_days must be a CloudWatch-supported retention value."
  }
}

variable "enable_container_insights" {
  description = "Whether to enable ECS Container Insights"
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS MySQL instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_allocated_storage" {
  description = "Initial RDS gp3 storage in GiB"
  type        = number
  default     = 30

  validation {
    condition     = var.rds_allocated_storage >= 20
    error_message = "rds_allocated_storage must be at least 20 GiB."
  }
}

variable "rds_max_allocated_storage" {
  description = "Maximum RDS autoscaled storage in GiB"
  type        = number
  default     = 100

  validation {
    condition     = var.rds_max_allocated_storage >= var.rds_allocated_storage
    error_message = "rds_max_allocated_storage must be greater than or equal to rds_allocated_storage."
  }
}

variable "rds_backup_retention_days" {
  description = "RDS automated backup retention"
  type        = number
  default     = 7
}

variable "valkey_snapshot_retention_days" {
  description = "Valkey Serverless snapshot retention"
  type        = number
  default     = 7
}

variable "stateful_instance_type" {
  description = "EC2 instance type used independently by each Judge stateful service"
  type        = string
  default     = "t3.small"

  validation {
    condition     = length(trimspace(var.stateful_instance_type)) > 0
    error_message = "stateful_instance_type must not be empty."
  }
}

variable "stateful_ebs_size" {
  description = "Persistent gp3 volume size per Judge stateful service"
  type        = number
  default     = 30

  validation {
    condition     = var.stateful_ebs_size >= 20
    error_message = "stateful_ebs_size must be at least 20 GiB."
  }
}

variable "enable_stateful_services" {
  description = "Create AI PostgreSQL, Judge PostgreSQL, and Redis task definitions/services after images and secrets are ready"
  type        = bool
  default     = false
}

variable "ai_postgres_image" {
  description = "Immutable full OCI image reference for AI PostgreSQL with pgvector"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.enable_stateful_services || can(regex("^[^[:space:]]+@sha256:[0-9a-f]{64}$", coalesce(var.ai_postgres_image, "")))
    error_message = "ai_postgres_image must be a full image reference pinned with a lowercase @sha256 digest when stateful services are enabled."
  }
}

variable "judge_postgres_image" {
  description = "Immutable full OCI image reference for Judge PostgreSQL"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.enable_stateful_services || can(regex("^[^[:space:]]+@sha256:[0-9a-f]{64}$", coalesce(var.judge_postgres_image, "")))
    error_message = "judge_postgres_image must be a full image reference pinned with @sha256 when stateful services are enabled."
  }
}

variable "judge_redis_image" {
  description = "Immutable full OCI image reference for Judge Valkey/Redis"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.enable_stateful_services || can(regex("^[^[:space:]]+@sha256:[0-9a-f]{64}$", coalesce(var.judge_redis_image, "")))
    error_message = "judge_redis_image must be a full image reference pinned with @sha256 when stateful services are enabled."
  }
}

variable "application_desired_count" {
  description = "Desired task count for each phase 2 application service"
  type        = number
  default     = 1

  validation {
    condition     = var.application_desired_count == 1
    error_message = "application_desired_count is fixed to 1 for the initial deployment."
  }
}

variable "enable_phase2_services" {
  description = "Create phase 2 Fargate task definitions/services after preflight succeeds"
  type        = bool
  default     = false
}

variable "spring_container_port" {
  type    = number
  default = 8080
}
variable "fastapi_container_port" {
  type    = number
  default = 8000
}
variable "judge_api_container_port" {
  type    = number
  default = 2358
}
variable "spring_cpu" {
  type    = number
  default = 1024
}
variable "spring_memory" {
  type    = number
  default = 2048
}
variable "fastapi_cpu" {
  type    = number
  default = 512
}
variable "fastapi_memory" {
  type    = number
  default = 1024
}
variable "judge_api_cpu" {
  type    = number
  default = 512
}
variable "judge_api_memory" {
  type    = number
  default = 1024
}

variable "spring_image_digest" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition     = !var.enable_phase2_services || can(regex("^sha256:[0-9a-f]{64}$", coalesce(var.spring_image_digest, "")))
    error_message = "spring_image_digest must be a lowercase sha256 digest when phase 2 services are enabled."
  }
}

variable "fastapi_image_digest" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition     = !var.enable_phase2_services || can(regex("^sha256:[0-9a-f]{64}$", coalesce(var.fastapi_image_digest, "")))
    error_message = "fastapi_image_digest must be a lowercase sha256 digest when phase 2 services are enabled."
  }
}

variable "judge_image_digest" {
  description = "Immutable shared Judge API/Worker image digest"
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = !(var.enable_phase2_services || var.enable_judge_worker) || can(regex("^sha256:[0-9a-f]{64}$", coalesce(var.judge_image_digest, "")))
    error_message = "judge_image_digest must be a lowercase sha256 digest when Judge API or Worker is enabled."
  }
}

variable "judge_api_command" {
  description = "Command used to start Judge API from the shared Judge image"
  type        = list(string)
  default     = ["./scripts/server"]

  validation {
    condition     = length(var.judge_api_command) > 0 && alltrue([for item in var.judge_api_command : length(trimspace(item)) > 0])
    error_message = "judge_api_command must contain at least one non-empty argument."
  }
}

variable "judge_worker_command" {
  description = "Command used to start Judge Worker from the shared Judge image"
  type        = list(string)
  default     = ["./scripts/workers"]

  validation {
    condition     = length(var.judge_worker_command) > 0 && alltrue([for item in var.judge_worker_command : length(trimspace(item)) > 0])
    error_message = "judge_worker_command must contain at least one non-empty argument."
  }
}

variable "enable_judge_worker_capacity" {
  description = "Create the dedicated Judge Worker launch template, ASGs, and capacity providers"
  type        = bool
  default     = false
}

variable "enable_judge_worker" {
  description = "Create the Judge Worker task definition and ECS service after capacity and runtime prerequisites are ready"
  type        = bool
  default     = false
}

variable "judge_worker_cpu" {
  description = "Judge Worker task CPU units"
  type        = number
  default     = 2048
}

variable "judge_worker_memory" {
  description = "Judge Worker task memory in MiB"
  type        = number
  default     = 2048
}

variable "judge_worker_desired_count" {
  description = "Manually controlled Judge Worker task count"
  type        = number
  default     = 1

  validation {
    condition     = var.judge_worker_desired_count >= 1 && var.judge_worker_desired_count <= 8
    error_message = "judge_worker_desired_count must be between 1 and 8."
  }
}

variable "worker_on_demand_instance_type" {
  description = "On-Demand Judge Worker EC2 instance type"
  type        = string
  default     = "c7i.large"
}

variable "worker_spot_instance_types" {
  description = "Ordered X86_64 instance candidates for the Judge Worker Spot ASG"
  type        = list(string)
  default     = ["c7i.large", "c6i.large", "c6a.large"]

  validation {
    condition = (
      length(var.worker_spot_instance_types) > 0 &&
      length(distinct(var.worker_spot_instance_types)) == length(var.worker_spot_instance_types) &&
      alltrue([for instance_type in var.worker_spot_instance_types : length(trimspace(instance_type)) > 0])
    )
    error_message = "worker_spot_instance_types must contain unique, non-empty instance types."
  }
}

variable "worker_spot_max_size" {
  description = "Maximum number of Spot instances for Judge Worker"
  type        = number
  default     = 7

  validation {
    condition     = var.worker_spot_max_size >= 4 && var.worker_spot_max_size <= 7
    error_message = "worker_spot_max_size must be between 4 and 7."
  }
}

variable "worker_root_volume_size" {
  description = "Encrypted gp3 root volume size for Judge Worker hosts"
  type        = number
  default     = 50

  validation {
    condition     = var.worker_root_volume_size >= 30
    error_message = "worker_root_volume_size must be at least 30 GiB."
  }
}

check "judge_worker_capacity_enabled" {
  assert {
    condition     = !var.enable_judge_worker || var.enable_judge_worker_capacity
    error_message = "enable_judge_worker_capacity must be true before enabling Judge Worker."
  }
}
