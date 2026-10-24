resource "aws_route53_record" "monitoring" {
  count = module.shared.monitoring_hostname == null ? 0 : 1

  zone_id = data.aws_route53_zone.main.zone_id
  name    = module.shared.monitoring_hostname
  type    = "A"
  ttl     = 300
  records = [module.shared.monitoring_public_ip]
}
