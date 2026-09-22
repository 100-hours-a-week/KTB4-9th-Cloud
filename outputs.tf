output "main_server_public_ip" {
  description = "메인 서버 공인 IP (SSH 접속 및 웹 접속용)"
  value       = aws_instance.main_server.public_ip
}

output "judge_server_private_ip" {
  description = "채점 서버 사설 IP (Main 서버에서 호출할 내부 주소)"
  value       = aws_instance.judge_server.private_ip
}

output "frontend_s3_bucket" {
  description = "React 빌드 파일을 업로드할 S3 버킷 이름"
  value       = aws_s3_bucket.frontend_bucket.id
}

output "frontend_cdn_url" {
  description = "사용자가 접속할 React 프론트엔드 CloudFront 기본 주소"
  value       = "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}"
}

output "custom_domain_url" {
  description = "가비아 도메인 연결 주소"
  value       = "https://${var.domain_name}"
}

output "route53_nameservers" {
  description = "가비아 네임서버 설정(1차~4차)에 등록해야 할 AWS Route 53 네임서버 목록"
  value       = aws_route53_zone.main.name_servers
}

output "judge_server_public_ip" {
  description = "채점 서버 공인 IP"
  value       = aws_instance.judge_server.public_ip
}

output "subdomain_dev_be_url" {
  description = "Spring Boot 백엔드 스웨거 및 API 접속 서브도메인 주소"
  value       = "http://${aws_route53_record.dev_be.name}"
}

output "subdomain_dev_ai_url" {
  description = "FastAPI AI 서버 스웨거 및 API 접속 서브도메인 주소"
  value       = "http://${aws_route53_record.dev_ai.name}"
}

output "subdomain_dev_judge_url" {
  description = "채점 서버 스웨거 접속 서브도메인 주소"
  value       = "http://${aws_route53_record.dev_judge.name}"
}