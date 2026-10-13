# HCP Terraform에서 shared Workspace의 remote-state consumer를 stage/prod로만 제한한다.
data "terraform_remote_state" "shared" {
  backend = "remote"
  config = {
    organization = "cosmoscode"
    workspaces = {
      name = "KTB4-9th-Cloud-v2-shared"
    }
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs
}

check "shared_output_contract" {
  assert {
    condition = (
      length(local.shared.public_subnet_ids) == 2 &&
      length(local.shared.private_subnet_ids) == 2 &&
      length(local.shared.data_subnet_ids) == 2 &&
      toset(keys(local.shared.ecr_repository_urls)) == toset(["spring", "fastapi", "judge"]) &&
      toset(keys(local.shared.ecr_repository_arns)) == toset(["spring", "fastapi", "judge"]) &&
      can(regex("^arn:aws:acm:ap-northeast-2:[0-9]{12}:certificate/", local.shared.regional_wildcard_certificate_arn))
    )
    error_message = "Shared Workspace output에 2AZ subnet과 ECR 3개가 필요합니다."
  }
}

module "environment" {
  source = "../../modules/environment"

  environment                       = "prod"
  vpc_id                            = data.terraform_remote_state.shared.outputs.vpc_id
  public_subnet_ids                 = data.terraform_remote_state.shared.outputs.public_subnet_ids
  private_subnet_ids                = data.terraform_remote_state.shared.outputs.private_subnet_ids
  data_subnet_ids                   = data.terraform_remote_state.shared.outputs.data_subnet_ids
  ecr_repository_urls               = data.terraform_remote_state.shared.outputs.ecr_repository_urls
  ecr_repository_arns               = data.terraform_remote_state.shared.outputs.ecr_repository_arns
  route53_zone_id                   = data.terraform_remote_state.shared.outputs.route53_zone_id
  cloudfront_certificate_arn        = data.terraform_remote_state.shared.outputs.cloudfront_certificate_arn
  regional_wildcard_certificate_arn = data.terraform_remote_state.shared.outputs.regional_wildcard_certificate_arn

  enable_stateful_services     = var.enable_stateful_services
  ai_postgres_image            = var.ai_postgres_image
  judge_postgres_image         = var.judge_postgres_image
  judge_redis_image            = var.judge_redis_image
  enable_phase2_services       = var.enable_phase2_services
  spring_image_digest          = var.spring_image_digest
  fastapi_image_digest         = var.fastapi_image_digest
  judge_image_digest           = var.judge_image_digest
  judge_api_command            = var.judge_api_command
  judge_worker_command         = var.judge_worker_command
  enable_judge_worker_capacity = var.enable_judge_worker_capacity
  enable_judge_worker          = var.enable_judge_worker
  judge_worker_desired_count   = var.judge_worker_desired_count
  enable_public_dns_cutover    = var.enable_public_dns_cutover
}
