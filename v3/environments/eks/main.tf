# v2 Shared가 관리하는 VPC는 읽기만 한다.
data "aws_vpc" "shared" {
  cidr_block = "10.20.0.0/16"

  tags = {
    Project = "cosmos"
  }
}

data "aws_route_table" "private_a" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "cosmos-v2-shared-private-1-rt"
  }
}

data "aws_route_table" "private_c" {
  vpc_id = data.aws_vpc.shared.id

  tags = {
    Name = "cosmos-v2-shared-private-2-rt"
  }
}

module "eks" {
  source = "../../modules/eks"

  vpc_id                   = data.aws_vpc.shared.id
  private_route_table_ids  = { a = data.aws_route_table.private_a.id, c = data.aws_route_table.private_c.id }
  public_access_cidrs      = var.public_access_cidrs
  rds_security_group_id    = "sg-0ad9b5d048b585831"
  valkey_security_group_id = "sg-0771c1aefded0effb"
  mlflow_bucket_arn        = "arn:aws:s3:::cosmos-v2-stage-mlflow-artifacts-352635536602"

  github_oidc_provider_arn = "arn:aws:iam::352635536602:oidc-provider/token.actions.githubusercontent.com"

  ci_promote_sub = "repo:100-hours-a-week@167328634/KTB4-9th-Cloud@1344702375:environment:eks-prod"
  ci_promote_images = {
    "cosmos-v2/spring"  = ["cosmos-auth", "cosmos-core", "cosmos-battle"]
    "cosmos-v2/fastapi" = ["cosmos-ai-llm", "cosmos-ai-make-problem", "cosmos-ai-problem-batch"]
  }

  workload_secrets = {
    auth-sa           = ["rds!db-a46a0c07-f0b9-4008-8625-fb7c744e7d1f", "/cosmos-v2/stage/spring", "cosmos/prod/spring-config"]
    core-sa           = ["rds!db-a46a0c07-f0b9-4008-8625-fb7c744e7d1f", "/cosmos-v2/stage/spring", "cosmos/prod/spring-config"]
    battle-sa         = ["rds!db-a46a0c07-f0b9-4008-8625-fb7c744e7d1f", "/cosmos-v2/stage/spring", "cosmos/prod/spring-config"]
    ai-llm-sa         = ["/cosmos-v2/stage/fastapi", "/cosmos-v2/stage/ai-postgres"]
    ai-job-sa         = ["/cosmos-v2/stage/fastapi", "/cosmos-v2/stage/ai-postgres"]
    ai-postgres-sa    = ["/cosmos-v2/stage/ai-postgres"]
    mlflow-sa         = ["/cosmos-v2/stage/ai-postgres"]
    judge-api-sa      = ["/cosmos-v2/stage/judge-api", "/cosmos-v2/stage/judge-postgres", "/cosmos-v2/stage/judge-redis"]
    judge-worker-sa   = ["/cosmos-v2/stage/judge-api", "/cosmos-v2/stage/judge-postgres", "/cosmos-v2/stage/judge-redis"]
    judge-postgres-sa = ["/cosmos-v2/stage/judge-postgres"]
    judge-redis-sa    = ["/cosmos-v2/stage/judge-redis"]
  }
}

data "aws_route53_zone" "main" {
  name         = "cosmoscode.site."
  private_zone = false
}

data "aws_lb" "prod" {
  name = "cosmos-v3-prod"
}

module "edge" {
  source = "../../modules/edge"
  providers = {
    aws.us_east_1 = aws.us_east_1
  }

  domain        = "eks.cosmoscode.site"
  zone_id       = data.aws_route53_zone.main.zone_id
  nlb_arn       = data.aws_lb.prod.arn
  nlb_dns_name  = data.aws_lb.prod.dns_name
  allowed_cidrs = var.edge_allowed_cidrs
}
