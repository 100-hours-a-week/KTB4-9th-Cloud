locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = "cosmos"
    Version     = "v2"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  frontend_aliases = var.environment == "stage" ? ["stage.${var.domain_name}"] : (
    var.enable_public_dns_cutover ? [var.domain_name, "www.${var.domain_name}"] : []
  )

  frontend_dns_names = var.environment == "stage" ? toset(["stage.${var.domain_name}"]) : (
    var.enable_public_dns_cutover ? toset([var.domain_name, "www.${var.domain_name}"]) : toset([])
  )

  ecr_repositories = toset(["spring", "fastapi", "judge-api"])

  secret_names = {
    spring         = "/cosmos-v2/${var.environment}/spring"
    fastapi        = "/cosmos-v2/${var.environment}/fastapi"
    ai-postgres    = "/cosmos-v2/${var.environment}/ai-postgres"
    judge-api      = "/cosmos-v2/${var.environment}/judge-api"
    judge-postgres = "/cosmos-v2/${var.environment}/judge-postgres"
    judge-redis    = "/cosmos-v2/${var.environment}/judge-redis"
    judge-worker   = "/cosmos-v2/${var.environment}/judge-worker"
  }

  stateful_services = {
    ai-postgres = {
      index              = "0"
      port               = 5432
      mount_path         = "/var/lib/postgresql/data"
      backup_retention   = 7
      memory_reservation = 1536
      image              = var.ai_postgres_image
      health_command     = ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d cosmos || exit 1"]
      writable_tmp_path  = "/tmp"
    }
    judge-postgres = {
      index              = "0"
      port               = 5432
      mount_path         = "/var/lib/postgresql/data"
      backup_retention   = 7
      memory_reservation = 1024
      image              = var.judge_postgres_image
      health_command     = ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB || exit 1"]
      writable_tmp_path  = "/tmp"
    }
    judge-redis = {
      index              = "1"
      port               = 6379
      mount_path         = "/data"
      backup_retention   = 3
      memory_reservation = 512
      image              = var.judge_redis_image
      health_command     = ["CMD-SHELL", "redis-cli -a $REDIS_PASSWORD ping | grep PONG"]
      writable_tmp_path  = "/tmp"
    }
  }

  enabled_stateful_services = var.enable_stateful_services ? local.stateful_services : {}

  application_services = {
    spring = {
      ecr_key        = "spring"
      command        = []
      port           = var.spring_container_port
      cpu            = var.spring_cpu
      memory         = var.spring_memory
      health_path    = "/api/actuator/health"
      health_command = []
      image_digest   = var.spring_image_digest
      server         = true
    }
    fastapi = {
      ecr_key     = "fastapi"
      command     = []
      port        = var.fastapi_container_port
      cpu         = var.fastapi_cpu
      memory      = var.fastapi_memory
      health_path = "/health"
      health_command = [
        "CMD-SHELL",
        "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${var.fastapi_container_port}/health')\"",
      ]
      image_digest = var.fastapi_image_digest
      server       = true
    }
    judge-api = {
      ecr_key     = "judge"
      command     = var.judge_api_command
      port        = var.judge_api_container_port
      cpu         = var.judge_api_cpu
      memory      = var.judge_api_memory
      health_path = "/"
      health_command = [
        "CMD-SHELL",
        "ruby -rnet/http -ruri -e \"exit(Net::HTTP.get_response(URI('http://127.0.0.1:${var.judge_api_container_port}/')).is_a?(Net::HTTPSuccess) ? 0 : 1)\"",
      ]
      image_digest = var.judge_image_digest
      server       = true
    }
  }

  enabled_application_services = var.enable_phase2_services ? local.application_services : {}

  stage_service_routes = var.environment == "stage" ? {
    spring = merge(local.application_services.spring, {
      hostname = "stage-be.${var.domain_name}"
      priority = 100
    })
    fastapi = merge(local.application_services.fastapi, {
      hostname = "stage-ai.${var.domain_name}"
      priority = 110
    })
    judge-api = merge(local.application_services["judge-api"], {
      hostname = "stage-judge.${var.domain_name}"
      priority = 120
    })
  } : {}

  stage_additional_target_services = {
    for key, service in local.stage_service_routes : key => service
    if key != "spring"
  }

  enabled_stage_service_routes = var.enable_phase2_services ? local.stage_service_routes : {}

  stage_swagger_root_routes = var.enable_phase2_services && var.environment == "stage" ? {
    fastapi = {
      hostname = local.stage_service_routes.fastapi.hostname
      priority = 105
    }
    judge-api = {
      hostname = local.stage_service_routes["judge-api"].hostname
      priority = 115
    }
  } : {}

  stage_service_urls = var.environment == "stage" ? {
    spring    = "https://${local.stage_service_routes.spring.hostname}"
    fastapi   = "https://${local.stage_service_routes.fastapi.hostname}"
    judge_api = "https://${local.stage_service_routes["judge-api"].hostname}"
  } : {}

  application_container_images = {
    for key, service in local.application_services :
    key => service.image_digest == null ? null : "${var.ecr_repository_urls[service.ecr_key]}@${service.image_digest}"
  }
  application_container_commands = { for key, service in local.application_services : key => service.command }

  worker_service = {
    name         = "judge-worker"
    cpu          = var.judge_worker_cpu
    memory       = var.judge_worker_memory
    image_digest = var.judge_image_digest
  }

  enabled_worker_capacity  = var.enable_judge_worker_capacity ? { worker = local.worker_service } : {}
  enabled_judge_worker     = var.enable_judge_worker && var.enable_judge_worker_capacity ? { worker = local.worker_service } : {}
  worker_container_image   = var.judge_image_digest == null ? null : "${var.ecr_repository_urls["judge"]}@${var.judge_image_digest}"
  worker_container_command = var.judge_worker_command
}
