locals {
  name        = "cosmos-v3-john"
  cidr_prefix = "10.30"
  domain      = "john.cosmoscode.site"
  rds_secret  = "cosmos/john/main-db"
  url_secret  = "cosmos/john/spring-config"
  spring      = [local.rds_secret, local.url_secret, "/cosmos-v2/stage/spring"]
}

module "network" {
  source      = "../../modules/network"
  name        = local.name
  cidr_prefix = local.cidr_prefix
}

resource "random_password" "mysql" {
  length  = 32
  special = false
}

module "data" {
  source              = "../../modules/data"
  name                = local.name
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.data_subnet_ids
  snapshot_identifier = var.seed_snapshot_identifier
  master_password     = random_password.mysql.result
}

# 운영 Secret은 읽기만 하고 DB 접속 정보만 이 클러스터 값으로 만든다.
data "aws_secretsmanager_secret_version" "source_url" {
  secret_id = "cosmos/prod/spring-config"
}

resource "aws_secretsmanager_secret" "main_db" {
  name                    = local.rds_secret
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "main_db" {
  secret_id = aws_secretsmanager_secret.main_db.id
  secret_string = jsonencode({
    username = module.data.mysql_username
    password = random_password.mysql.result
  })
}

resource "aws_secretsmanager_secret" "spring_config" {
  name                    = local.url_secret
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "spring_config" {
  secret_id = aws_secretsmanager_secret.spring_config.id
  secret_string = jsonencode({
    DB_URL = replace(jsondecode(data.aws_secretsmanager_secret_version.source_url.secret_string).DB_URL, "/jdbc:mysql:\\/\\/[^:\\/]+/", "jdbc:mysql://${module.data.mysql_address}")
  })
}

resource "aws_s3_bucket" "mlflow" {
  bucket        = "${local.name}-mlflow-352635536602"
  force_destroy = true
}

module "eks" {
  source = "../../modules/eks"

  cluster_name            = local.name
  vpc_id                  = module.network.vpc_id
  private_route_table_ids = { a = module.network.private_route_table_id, c = module.network.private_route_table_id }
  subnets = {
    a = { availability_zone = "ap-northeast-2a", cidr_block = "${local.cidr_prefix}.32.0/20" }
    c = { availability_zone = "ap-northeast-2c", cidr_block = "${local.cidr_prefix}.48.0/20" }
  }
  public_access_cidrs = var.public_access_cidrs
  mlflow_bucket_arn   = aws_s3_bucket.mlflow.arn

  workload_secrets = {
    auth-sa           = local.spring
    core-sa           = local.spring
    battle-sa         = local.spring
    ai-llm-sa         = ["/cosmos-v2/stage/fastapi", "/cosmos-v2/stage/ai-postgres"]
    ai-job-sa         = ["/cosmos-v2/stage/fastapi", "/cosmos-v2/stage/ai-postgres"]
    ai-postgres-sa    = ["/cosmos-v2/stage/ai-postgres"]
    mlflow-sa         = ["/cosmos-v2/stage/ai-postgres"]
    judge-api-sa      = ["/cosmos-v2/stage/judge-api", "/cosmos-v2/stage/judge-postgres", "/cosmos-v2/stage/judge-redis"]
    judge-worker-sa   = ["/cosmos-v2/stage/judge-api", "/cosmos-v2/stage/judge-postgres", "/cosmos-v2/stage/judge-redis"]
    judge-postgres-sa = ["/cosmos-v2/stage/judge-postgres"]
    judge-redis-sa    = ["/cosmos-v2/stage/judge-redis"]
  }

  depends_on = [aws_secretsmanager_secret_version.main_db, aws_secretsmanager_secret_version.spring_config]
}

resource "aws_vpc_security_group_ingress_rule" "mysql_from_eks" {
  security_group_id            = module.data.mysql_sg_id
  referenced_security_group_id = module.eks.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_eks" {
  security_group_id            = module.data.valkey_sg_id
  referenced_security_group_id = module.eks.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

data "aws_route53_zone" "main" {
  name         = "cosmoscode.site."
  private_zone = false
}

# NLB는 Envoy가 만들므로 up.sh가 클러스터 구성 후 enable_edge=true로 다시 적용한다.
data "aws_lb" "prod" {
  count = var.enable_edge ? 1 : 0
  name  = local.name
}

module "edge" {
  count  = var.enable_edge ? 1 : 0
  source = "../../modules/edge"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain        = local.domain
  zone_id       = data.aws_route53_zone.main.zone_id
  nlb_arn       = data.aws_lb.prod[0].arn
  nlb_dns_name  = data.aws_lb.prod[0].dns_name
  allowed_cidrs = var.edge_allowed_cidrs
}

module "edge_argocd" {
  count  = var.enable_edge ? 1 : 0
  source = "../../modules/edge-internal"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain        = "argocd-john.cosmoscode.site"
  zone_id       = data.aws_route53_zone.main.zone_id
  nlb_dns_name  = data.aws_lb.prod[0].dns_name
  vpc_origin_id = module.edge[0].vpc_origin_id
  web_acl_arn   = module.edge[0].web_acl_arn
}

module "edge_grafana" {
  count  = var.enable_edge ? 1 : 0
  source = "../../modules/edge-internal"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain        = "grafana-john.cosmoscode.site"
  zone_id       = data.aws_route53_zone.main.zone_id
  nlb_dns_name  = data.aws_lb.prod[0].dns_name
  vpc_origin_id = module.edge[0].vpc_origin_id
  web_acl_arn   = module.edge[0].web_acl_arn
}
