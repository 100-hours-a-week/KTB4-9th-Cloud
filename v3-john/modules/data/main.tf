# 메인 DB는 시드 스냅샷에서 복원하고 Valkey는 빈 상태로 만든다.
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "snapshot_identifier" { type = string }
variable "master_password" {
  type      = string
  sensitive = true
}

resource "aws_security_group" "mysql" {
  name   = "${var.name}-mysql"
  vpc_id = var.vpc_id
}

resource "aws_security_group" "valkey" {
  name   = "${var.name}-valkey"
  vpc_id = var.vpc_id
}

resource "aws_db_subnet_group" "main" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "main" {
  identifier              = "${var.name}-mysql"
  snapshot_identifier     = var.snapshot_identifier
  instance_class          = "db.t4g.medium"
  storage_type            = "gp3"
  multi_az                = false
  password                = var.master_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.mysql.id]
  parameter_group_name    = "default.mysql8.4"
  publicly_accessible     = false
  apply_immediately       = true
  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true
}

resource "aws_elasticache_serverless_cache" "main" {
  name                 = "${var.name}-backend"
  engine               = "valkey"
  major_engine_version = "9"
  subnet_ids           = var.subnet_ids
  security_group_ids   = [aws_security_group.valkey.id]
}

output "mysql_address" { value = aws_db_instance.main.address }
output "mysql_username" { value = aws_db_instance.main.username }
output "mysql_sg_id" { value = aws_security_group.mysql.id }
output "valkey_sg_id" { value = aws_security_group.valkey.id }
