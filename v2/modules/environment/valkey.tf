resource "aws_elasticache_user" "spring" {
  user_id       = "${local.name_prefix}-spring"
  user_name     = "${local.name_prefix}-spring"
  engine        = "VALKEY"
  access_string = "on ~* +@all"

  authentication_mode {
    type = "iam"
  }
}

resource "aws_elasticache_user_group" "backend" {
  engine        = "VALKEY"
  user_group_id = "${local.name_prefix}-backend"
  user_ids      = [aws_elasticache_user.spring.user_id]
}

resource "aws_elasticache_serverless_cache" "backend" {
  name                     = "${local.name_prefix}-backend"
  engine                   = "valkey"
  description              = "COSMOS v2 Spring backend Valkey"
  security_group_ids       = [aws_security_group.data["backend-valkey"].id]
  subnet_ids               = values(var.data_subnet_ids)
  user_group_id            = aws_elasticache_user_group.backend.user_group_id
  snapshot_retention_limit = var.valkey_snapshot_retention_days

  tags = { Name = "${local.name_prefix}-backend" }
}
