locals {
  enable_loki_forwarding = var.monitoring_private_ip != null
  loki_log_group_names = merge(
    { for key, group in aws_cloudwatch_log_group.service : key => group.name },
    { for key, group in aws_cloudwatch_log_group.stateful : key => group.name },
    { "judge-worker" = aws_cloudwatch_log_group.worker.name },
    var.environment == "stage" ? { "mlflow" = "/ecs/${local.name_prefix}/mlflow" } : {},
  )
}

data "archive_file" "cloudwatch_to_loki" {
  count = local.enable_loki_forwarding ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/cloudwatch_to_loki.py"
  output_path = "${path.module}/.terraform/cloudwatch_to_loki.zip"
}

resource "aws_iam_role" "cloudwatch_to_loki" {
  count = local.enable_loki_forwarding ? 1 : 0

  name = "${local.name_prefix}-cloudwatch-to-loki"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_to_loki_basic" {
  count = local.enable_loki_forwarding ? 1 : 0

  role       = aws_iam_role.cloudwatch_to_loki[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_to_loki_vpc" {
  count = local.enable_loki_forwarding ? 1 : 0

  role       = aws_iam_role.cloudwatch_to_loki[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "cloudwatch_to_loki" {
  count = local.enable_loki_forwarding ? 1 : 0

  name        = "${local.name_prefix}-cloudwatch-to-loki-sg"
  description = "CloudWatch Logs subscription Lambda egress to private Loki"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-cloudwatch-to-loki-sg" })
}

resource "aws_vpc_security_group_egress_rule" "cloudwatch_to_loki" {
  count = local.enable_loki_forwarding ? 1 : 0

  security_group_id = aws_security_group.cloudwatch_to_loki[0].id
  cidr_ipv4         = "${var.monitoring_private_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 3100
  to_port           = 3100
}

resource "aws_vpc_security_group_ingress_rule" "loki_from_forwarder" {
  count = local.enable_loki_forwarding ? 1 : 0

  security_group_id            = var.monitoring_security_group_id
  referenced_security_group_id = aws_security_group.cloudwatch_to_loki[0].id
  description                  = "Allow the CloudWatch Logs forwarder to push to Loki"
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
}

resource "aws_lambda_function" "cloudwatch_to_loki" {
  count = local.enable_loki_forwarding ? 1 : 0

  function_name    = "${local.name_prefix}-cloudwatch-to-loki"
  role             = aws_iam_role.cloudwatch_to_loki[0].arn
  handler          = "cloudwatch_to_loki.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.cloudwatch_to_loki[0].output_path
  source_code_hash = data.archive_file.cloudwatch_to_loki[0].output_base64sha256
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      ENVIRONMENT   = var.environment
      LOKI_BASE_URL = "http://${var.monitoring_private_ip}:3100"
    }
  }

  vpc_config {
    subnet_ids         = values(var.private_subnet_ids)
    security_group_ids = [aws_security_group.cloudwatch_to_loki[0].id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cloudwatch_to_loki_basic,
    aws_iam_role_policy_attachment.cloudwatch_to_loki_vpc,
  ]

  tags = local.common_tags
}

resource "aws_lambda_permission" "cloudwatch_logs" {
  count = local.enable_loki_forwarding ? 1 : 0

  statement_id  = "AllowCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudwatch_to_loki[0].function_name
  principal     = "logs.${var.aws_region}.amazonaws.com"
  source_arn    = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name_prefix}/*:*"
}

resource "aws_cloudwatch_log_subscription_filter" "loki" {
  for_each = local.enable_loki_forwarding ? local.loki_log_group_names : {}

  name            = "forward-to-loki"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = aws_lambda_function.cloudwatch_to_loki[0].arn

  depends_on = [aws_lambda_permission.cloudwatch_logs]
}
