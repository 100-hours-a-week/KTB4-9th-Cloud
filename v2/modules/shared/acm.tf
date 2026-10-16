resource "aws_acm_certificate" "regional_wildcard" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-shared-regional-wildcard"
  })
}

resource "aws_acm_certificate_validation" "regional_wildcard" {
  certificate_arn = aws_acm_certificate.regional_wildcard.arn
  validation_record_fqdns = [
    for option in aws_acm_certificate.regional_wildcard.domain_validation_options :
    option.resource_record_name
  ]
}

