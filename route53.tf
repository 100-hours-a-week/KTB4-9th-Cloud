# 1. Route 53 공용 호스팅 영역 (도메인: cosmoscode.site)
resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Managed by Terraform for ${var.project_name}"

  tags = {
    Name = "${var.project_name}-route53-zone"
  }
}

# 2. AWS Certificate Manager (ACM) 무료 SSL 인증서 발급
# 주의: CloudFront와 연결하는 ACM 인증서는 반드시 us-east-1(버지니아 북부) 리전에서 생성해야 함
resource "aws_acm_certificate" "cert" {
  provider                  = aws.us_east_1
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-acm-certificate"
  }
}

# 3. Route 53에 ACM 도메인 소유권 검증용 CNAME 레코드 자동 생성
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

# 4. ACM 인증서 검증 대기 및 완료
resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# 5. Route 53 Apex 도메인(cosmoscode.site) ➜ CloudFront Alias 레코드
resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.frontend_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# 6. Route 53 www 서브도메인(www.cosmoscode.site) ➜ CloudFront Alias 레코드
resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.frontend_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}
