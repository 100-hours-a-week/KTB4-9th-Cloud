data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ==============================================================================
# 기존 v2 기반 리소스 읽기 전용 참조 (수정 및 삭제 권한 없음)
# ==============================================================================
data "aws_vpc" "shared" {
  filter {
    name   = "tag:Name"
    values = ["cosmos-v2-shared-vpc"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }
  filter {
    name   = "tag:Name"
    values = ["cosmos-v2-shared-private-*"]
  }
}

data "aws_lb" "stage" {
  name = "cosmos-v2-stage-alb"
}

data "aws_lb_listener" "stage_https" {
  load_balancer_arn = data.aws_lb.stage.arn
  port              = 443
}

data "aws_ecs_cluster" "stage" {
  cluster_name = "cosmos-v2-stage-cluster"
}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

data "aws_security_group" "alb" {
  filter {
    name   = "tag:Name"
    values = ["cosmos-v2-stage-alb-sg"]
  }
}

data "aws_security_group" "ai_postgres" {
  filter {
    name   = "tag:Name"
    values = ["cosmos-v2-stage-ai-postgres-sg"]
  }
}

data "aws_service_discovery_http_namespace" "stage" {
  name = "stage.cosmos-v2.local"
}

data "aws_secretsmanager_secret" "ai_postgres" {
  name = "/cosmos-v2/stage/ai-postgres"
}

# ==============================================================================
# MLflow 전용 S3 아티팩트 버킷
# ==============================================================================
resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket        = "cosmos-v2-stage-mlflow-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Name = "cosmos-v2-stage-mlflow-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==============================================================================
# MLflow Fargate 태스크 보안 그룹 및 PostgreSQL 연동 인그레스
# ==============================================================================
resource "aws_security_group" "mlflow_task" {
  name        = "cosmos-v2-stage-mlflow-task-sg"
  description = "Security group for MLflow Fargate task"
  vpc_id      = data.aws_vpc.shared.id

  ingress {
    description     = "Allow HTTP 5000 from ALB"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [data.aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound traffic (S3, PyPI, PostgreSQL)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cosmos-v2-stage-mlflow-task-sg"
  }
}

# ai-postgres 보안 그룹에 MLflow 태스크에서의 접근 허용 규칙 추가
resource "aws_security_group_rule" "ai_postgres_ingress_mlflow" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.ai_postgres.id
  source_security_group_id = aws_security_group.mlflow_task.id
  description              = "Allow PostgreSQL 5432 from MLflow Fargate task"
}

# ==============================================================================
# IAM 역할 (Execution Role & Task Role)
# ==============================================================================
resource "aws_iam_role" "mlflow_task_execution" {
  name = "cosmos-v2-stage-mlflow-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mlflow_task_execution" {
  role       = aws_iam_role.mlflow_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager 읽기 권한 (ai-postgres DB 패스워드 주입용)
resource "aws_iam_role_policy" "mlflow_secrets" {
  name = "cosmos-v2-stage-mlflow-secrets-policy"
  role = aws_iam_role.mlflow_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [data.aws_secretsmanager_secret.ai_postgres.arn]
    }]
  })
}

resource "aws_iam_role" "mlflow_task" {
  name = "cosmos-v2-stage-mlflow-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

# S3 아티팩트 버킷 읽기/쓰기 권한
resource "aws_iam_role_policy" "mlflow_s3" {
  name = "cosmos-v2-stage-mlflow-s3-policy"
  role = aws_iam_role.mlflow_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetBucketLocation",
        "s3:ListBucket"
      ]
      Resource = [aws_s3_bucket.mlflow_artifacts.arn]
      }, {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ]
      Resource = ["${aws_s3_bucket.mlflow_artifacts.arn}/*"]
    }]
  })
}

# ==============================================================================
# CloudWatch Log Group
# ==============================================================================
resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/ecs/cosmos-v2-stage/mlflow"
  retention_in_days = 7

  tags = {
    Name = "cosmos-v2-stage-mlflow-logs"
  }
}

# ==============================================================================
# ALB 타깃 그룹 & 443 리스너 라우팅 규칙
# ==============================================================================
resource "aws_lb_target_group" "mlflow" {
  name        = "cosmos-v2-stage-mlflow"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.shared.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "5000"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "cosmos-v2-stage-mlflow-tg"
  }
}

resource "aws_lb_listener_rule" "mlflow" {
  listener_arn = data.aws_lb_listener.stage_https.arn
  priority     = var.alb_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mlflow.arn
  }

  condition {
    host_header {
      values = [var.mlflow_hostname]
    }
  }
}

# ==============================================================================
# Route 53 A 레코드 (mlflow.cosmoscode.site -> ALB)
# ==============================================================================
resource "aws_route53_record" "mlflow" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.mlflow_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.stage.dns_name
    zone_id                = data.aws_lb.stage.zone_id
    evaluate_target_health = true
  }
}

# ==============================================================================
# ECS Fargate Task Definition & Service
# ==============================================================================
resource "aws_ecs_task_definition" "mlflow" {
  family                   = "cosmos-v2-stage-mlflow"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.mlflow_cpu)
  memory                   = tostring(var.mlflow_memory)
  execution_role_arn       = aws_iam_role.mlflow_task_execution.arn
  task_role_arn            = aws_iam_role.mlflow_task.arn

  container_definitions = jsonencode([{
    name      = "mlflow"
    image     = var.mlflow_image
    essential = true

    portMappings = [{
      name          = "mlflow"
      containerPort = 5000
      hostPort      = 5000
      protocol      = "tcp"
    }]

    entryPoint = ["sh", "-c"]
    command = [
      <<-EOT
      pip install --no-cache-dir boto3 psycopg2-binary && \
      mlflow server \
        --backend-store-uri "postgresql://cosmos_ai:$${POSTGRES_PASSWORD}@ai-postgres:5432/mlflow" \
        --default-artifact-root "s3://${aws_s3_bucket.mlflow_artifacts.id}/" \
        --host 0.0.0.0 \
        --port 5000
      EOT
    ]

    secrets = [{
      name      = "POSTGRES_PASSWORD"
      valueFrom = "${data.aws_secretsmanager_secret.ai_postgres.arn}:password::"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.mlflow.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "ecs"
      }
    }
  }])

  tags = {
    Name = "cosmos-v2-stage-mlflow-task"
  }
}

resource "aws_ecs_service" "mlflow" {
  name            = "cosmos-v2-stage-mlflow"
  cluster         = data.aws_ecs_cluster.stage.id
  task_definition = aws_ecs_task_definition.mlflow.arn
  desired_count   = var.mlflow_desired_count
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 180

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.mlflow_task.id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = data.aws_service_discovery_http_namespace.stage.arn

    service {
      port_name      = "mlflow"
      discovery_name = "mlflow"
      client_alias {
        dns_name = "mlflow"
        port     = 5000
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "mlflow"
    container_port   = 5000
  }

  depends_on = [
    aws_lb_listener_rule.mlflow,
    aws_iam_role_policy.mlflow_secrets,
    aws_iam_role_policy.mlflow_s3,
    aws_security_group_rule.ai_postgres_ingress_mlflow,
  ]

  tags = {
    Name = "cosmos-v2-stage-mlflow-service"
  }
}
