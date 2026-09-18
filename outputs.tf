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
  description = "사용자가 접속할 React 프론트엔드 CloudFront 주소"
  value       = "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}"
}