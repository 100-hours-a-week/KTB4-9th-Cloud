# 테스트용 MySQL과 Valkey는 매번 빈 상태로 만든다.
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
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
  identifier                  = "${var.name}-mysql"
  engine                      = "mysql"
  engine_version              = "8.4.11"
  allow_major_version_upgrade = true
  instance_class              = "db.t4g.medium"
  db_name                     = "cosmos"
  username                    = "cosmos_admin"
  password                    = var.master_password
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = false
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.mysql.id]
  parameter_group_name        = "default.mysql8.4"
  publicly_accessible         = false
  apply_immediately           = true
  backup_retention_period     = 0
  deletion_protection         = false
  skip_final_snapshot         = true
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
