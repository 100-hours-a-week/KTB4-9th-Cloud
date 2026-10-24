output "vpc_id" { value = module.shared.vpc_id }
output "public_subnet_ids" { value = module.shared.public_subnet_ids }
output "private_subnet_ids" { value = module.shared.private_subnet_ids }
output "data_subnet_ids" { value = module.shared.data_subnet_ids }
output "ecr_repository_urls" { value = module.shared.ecr_repository_urls }
output "ecr_repository_arns" { value = module.shared.ecr_repository_arns }
output "github_stage_ci_role_arns" { value = module.shared.github_stage_ci_role_arns }
output "github_oidc_provider_arn" { value = module.shared.github_oidc_provider_arn }
output "nat_gateway_id" { value = module.shared.nat_gateway_id }
output "s3_gateway_endpoint_id" { value = module.shared.s3_gateway_endpoint_id }
output "route53_zone_id" { value = data.aws_route53_zone.main.zone_id }
output "cloudfront_certificate_arn" { value = data.aws_acm_certificate.cloudfront.arn }
output "regional_wildcard_certificate_arn" { value = module.shared.regional_wildcard_certificate_arn }

output "monitoring_url" {
  description = "Grafana URL"
  value       = module.shared.monitoring_hostname == null ? null : "https://${module.shared.monitoring_hostname}"
}

output "monitoring_instance_id" { value = module.shared.monitoring_instance_id }
output "monitoring_private_ip" { value = module.shared.monitoring_private_ip }
output "monitoring_public_ip" { value = module.shared.monitoring_public_ip }
output "monitoring_security_group_id" { value = module.shared.monitoring_security_group_id }
output "monitoring_config_bucket_name" { value = module.shared.monitoring_config_bucket_name }
output "monitoring_admin_secret_arn" { value = module.shared.monitoring_admin_secret_arn }
