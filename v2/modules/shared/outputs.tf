output "vpc_id" {
  description = "공유 VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "문자열 index를 key로 하는 Public subnet ID map"
  value       = { for key, subnet in aws_subnet.public : key => subnet.id }
}

output "private_subnet_ids" {
  description = "문자열 index를 key로 하는 Private subnet ID map"
  value       = { for key, subnet in aws_subnet.private : key => subnet.id }
}

output "data_subnet_ids" {
  description = "문자열 index를 key로 하는 Data subnet ID map"
  value       = { for key, subnet in aws_subnet.data : key => subnet.id }
}

output "ecr_repository_urls" {
  description = "서비스명별 공유 ECR URL"
  value       = { for key, repository in aws_ecr_repository.service : key => repository.repository_url }
}

output "ecr_repository_arns" {
  description = "서비스명별 공유 ECR ARN"
  value       = { for key, repository in aws_ecr_repository.service : key => repository.arn }
}

output "github_stage_ci_role_arns" {
  description = "서비스 repository별 GitHub Stage CI ECR push role ARN"
  value       = { for key, role in aws_iam_role.github_stage_ci : key => role.arn }
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "nat_gateway_id" {
  description = "공유 NAT Gateway ID"
  value       = aws_nat_gateway.main[0].id
}

output "s3_gateway_endpoint_id" {
  description = "공유 S3 Gateway Endpoint ID"
  value       = aws_vpc_endpoint.s3.id
}

output "regional_wildcard_certificate_arn" {
  description = "서울 리전 ALB용 wildcard ACM 인증서 ARN"
  value       = aws_acm_certificate_validation.regional_wildcard.certificate_arn
}
