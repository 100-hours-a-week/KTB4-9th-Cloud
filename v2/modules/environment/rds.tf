resource "aws_db_subnet_group" "mysql" {
  name       = "${local.name_prefix}-mysql"
  subnet_ids = values(var.data_subnet_ids)

  tags = { Name = "${local.name_prefix}-mysql" }
}

resource "aws_db_instance" "mysql" {
  identifier = "${local.name_prefix}-mysql"

  engine                      = "mysql"
  engine_version              = "8.0"
  instance_class              = var.rds_instance_class
  db_name                     = "cosmos"
  username                    = "cosmos_admin"
  manage_master_user_password = true

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.data["rds-mysql"].id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period   = var.rds_backup_retention_days
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-mysql-final"
  apply_immediately         = false

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  tags = { Name = "${local.name_prefix}-mysql" }
}

