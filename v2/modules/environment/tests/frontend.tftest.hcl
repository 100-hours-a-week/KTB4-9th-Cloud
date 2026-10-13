variables {
  environment                       = "stage"
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
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }
  override_data {
    target = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing
    values = { id = "pl-cloudfront" }
  }
  override_data {
    target = data.aws_cloudfront_cache_policy.caching_optimized
    values = { id = "cache-optimized" }
  }
  override_data {
    target = data.aws_cloudfront_cache_policy.caching_disabled
    values = { id = "cache-disabled" }
  }
  override_data {
    target = data.aws_cloudfront_origin_request_policy.all_viewer
    values = { id = "origin-all-viewer" }
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
    target = data.aws_ssm_parameter.ecs_optimized_al2023
    values = { value = "ami-test" }
  }
  override_resource {
    target          = aws_lb.main
    override_during = plan
    values = {
      arn      = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/cosmos-v2-stage-alb/1234567890abcdef"
      dns_name = "stage-alb.example.amazonaws.com"
      zone_id  = "ZALBSTAGE123"
    }
  }
  override_resource {
    target = aws_s3_bucket.frontend
    values = {
      arn                         = "arn:aws:s3:::cosmos-v2-stage-frontend-123456789012"
      bucket_regional_domain_name = "cosmos-v2-stage-frontend-123456789012.s3.ap-northeast-2.amazonaws.com"
    }
  }
  override_resource {
    target = aws_cloudfront_distribution.frontend
    values = {
      arn            = "arn:aws:cloudfront::123456789012:distribution/TEST"
      domain_name    = "d123.cloudfront.net"
      hosted_zone_id = "Z2FDTNDATAQYW2"
    }
  }
}

run "stage_frontend는_private_S3와_CloudFront를_사용한다" {
  command = plan

  assert {
    condition     = aws_s3_bucket.frontend.bucket == "cosmos-v2-stage-frontend-123456789012"
    error_message = "stage frontend bucket 이름에 환경과 account ID가 필요합니다."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.frontend.block_public_acls &&
      aws_s3_bucket_public_access_block.frontend.block_public_policy &&
      aws_s3_bucket_public_access_block.frontend.ignore_public_acls &&
      aws_s3_bucket_public_access_block.frontend.restrict_public_buckets
    )
    error_message = "frontend S3의 public access는 모두 차단해야 합니다."
  }

  assert {
    condition = (
      aws_cloudfront_origin_access_control.frontend.origin_access_control_origin_type == "s3" &&
      aws_cloudfront_origin_access_control.frontend.signing_behavior == "always" &&
      aws_cloudfront_origin_access_control.frontend.signing_protocol == "sigv4"
    )
    error_message = "CloudFront OAC는 S3 SigV4 always를 사용해야 합니다."
  }

  assert {
    condition = (
      local.frontend_bucket_policy.Statement[0].Principal.Service == "cloudfront.amazonaws.com" &&
      local.frontend_bucket_policy.Statement[0].Action == "s3:GetObject" &&
      contains(keys(local.frontend_bucket_policy.Statement[0].Condition.StringEquals), "AWS:SourceArn")
    )
    error_message = "S3 bucket policy는 자신의 CloudFront distribution만 읽도록 제한해야 합니다."
  }

  assert {
    condition     = aws_cloudfront_distribution.frontend.aliases == toset(["stage.cosmoscode.site"])
    error_message = "stage CloudFront alias는 stage.cosmoscode.site 하나여야 합니다."
  }

  assert {
    condition = (
      length(aws_cloudfront_distribution.frontend.ordered_cache_behavior) == 3 &&
      aws_cloudfront_distribution.frontend.ordered_cache_behavior[0].path_pattern == "/api/*" &&
      aws_cloudfront_distribution.frontend.ordered_cache_behavior[1].path_pattern == "/auth/*" &&
      aws_cloudfront_distribution.frontend.ordered_cache_behavior[2].path_pattern == "/index.html"
    )
    error_message = "CloudFront는 S3/ALB origin과 API/Auth/Index behavior를 가져야 합니다."
  }

  assert {
    condition = (
      length(aws_cloudfront_distribution.frontend.custom_error_response) == 0 &&
      length(one(aws_cloudfront_distribution.frontend.default_cache_behavior).function_association) == 1 &&
      one(one(aws_cloudfront_distribution.frontend.default_cache_behavior).function_association).event_type == "viewer-request" &&
      aws_cloudfront_function.spa_rewrite.name == "cosmos-v2-stage-spa-rewrite" &&
      strcontains(aws_cloudfront_function.spa_rewrite.code, "uri.startsWith('/api/')") &&
      strcontains(aws_cloudfront_function.spa_rewrite.code, "uri.startsWith('/auth/')") &&
      one(aws_cloudfront_distribution.frontend.viewer_certificate).minimum_protocol_version == "TLSv1.2_2021"
    )
    error_message = "SPA rewrite는 S3 기본 behavior에만 적용해 API 403/404를 보존하고 TLS 1.2_2021을 사용해야 합니다."
  }
}

run "stage_DNS와_ALB는_CloudFront만_허용한다" {
  command = plan

  assert {
    condition     = length(aws_route53_record.frontend) == 1 && aws_route53_record.frontend["stage.cosmoscode.site"].name == "stage.cosmoscode.site"
    error_message = "stage public DNS는 frontend alias 하나여야 합니다."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.alb_from_cloudfront.prefix_list_id == "pl-cloudfront" &&
      aws_vpc_security_group_ingress_rule.alb_from_cloudfront.from_port == 80 &&
      aws_vpc_security_group_ingress_rule.alb_from_cloudfront.to_port == 80
    )
    error_message = "ALB HTTP ingress는 CloudFront origin prefix list만 허용해야 합니다."
  }


  assert {
    condition = (
      toset(keys(aws_route53_record.stage_service)) == toset(["spring", "fastapi", "judge-api"]) &&
      toset([for record in aws_route53_record.stage_service : record.name]) == toset([
        "stage-be.cosmoscode.site",
        "stage-ai.cosmoscode.site",
        "stage-judge.cosmoscode.site",
      ]) &&
      alltrue([
        for record in aws_route53_record.stage_service :
        one(record.alias).name == "stage-alb.example.amazonaws.com" &&
        one(record.alias).zone_id == "ZALBSTAGE123" &&
        one(record.alias).evaluate_target_health
      ])
    )
    error_message = "Stage 서비스 DNS 3개는 같은 ALB를 향하는 health-evaluated A Alias여야 합니다."
  }

  assert {
    condition = (
      output.stage_service_urls.spring == "https://stage-be.cosmoscode.site" &&
      output.stage_service_urls.fastapi == "https://stage-ai.cosmoscode.site" &&
      output.stage_service_urls.judge_api == "https://stage-judge.cosmoscode.site"
    )
    error_message = "Stage output은 세 서비스의 HTTPS base URL을 제공해야 합니다."
  }
}

run "prod_DNS_cutover는_기본적으로_비활성이다" {
  command = plan
  variables { environment = "prod" }

  assert {
    condition = (
      length(aws_route53_record.frontend) == 0 &&
      length(aws_route53_record.stage_service) == 0 &&
      length(output.stage_service_urls) == 0 &&
      length(aws_cloudfront_distribution.frontend.aliases) == 0
    )
    error_message = "prod cutover 전에는 apex/www record와 alias를 만들면 안 됩니다."
  }
}

run "prod_DNS_cutover를_승인하면_apex와_www를_생성한다" {
  command = plan
  variables {
    environment               = "prod"
    enable_public_dns_cutover = true
  }

  assert {
    condition     = toset(keys(aws_route53_record.frontend)) == toset(["cosmoscode.site", "www.cosmoscode.site"])
    error_message = "승인된 prod cutover는 apex와 www alias 두 개를 생성해야 합니다."
  }
}

run "CloudFront_인증서가_us_east_1이_아니면_거부한다" {
  command = plan
  variables {
    cloudfront_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/test"
  }
  expect_failures = [var.cloudfront_certificate_arn]
}
