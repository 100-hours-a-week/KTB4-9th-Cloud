resource "aws_secretsmanager_secret" "service" {
  for_each = local.secret_names

  name                    = each.value
  description             = "Runtime secret metadata for ${each.key}; values are managed outside Terraform"
  recovery_window_in_days = 30

  tags = { Service = each.key }
}
