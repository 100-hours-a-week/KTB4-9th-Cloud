module "shared" {
  source = "../../modules/shared"
}

data "aws_route53_zone" "main" {
  name         = "cosmoscode.site."
  private_zone = false
}

data "aws_acm_certificate" "cloudfront" {
  provider    = aws.us_east_1
  domain      = "cosmoscode.site"
  statuses    = ["ISSUED"]
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

check "cloudfront_certificate_covers_domains" {
  assert {
    condition     = data.aws_acm_certificate.cloudfront.domain == "cosmoscode.site" && strcontains(data.aws_acm_certificate.cloudfront.arn, ":us-east-1:")
    error_message = "CloudFront 인증서는 us-east-1의 cosmoscode.site ISSUED 인증서여야 합니다."
  }
}

