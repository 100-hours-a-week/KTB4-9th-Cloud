# ==============================================================================
# CloudWatch Logs -> Discord Webhook 배치 알림 람다
# ==============================================================================

data "archive_file" "discord_notifier" {
  type        = "zip"
  source_file = "${path.module}/lambda/discord_notifier.py"
  output_path = "${path.module}/lambda/discord_notifier.zip"
}

resource "aws_iam_role" "discord_notifier_lambda" {
  name = "${local.name_prefix}-discord-notifier-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-discord-notifier-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "discord_notifier_basic" {
  role       = aws_iam_role.discord_notifier_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "discord_notifier" {
  filename         = data.archive_file.discord_notifier.output_path
  source_code_hash = data.archive_file.discord_notifier.output_base64sha256
  function_name    = "${local.name_prefix}-batch-discord-notifier"
  role             = aws_iam_role.discord_notifier_lambda.arn
  handler          = "discord_notifier.handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }

  tags = {
    Name = "${local.name_prefix}-batch-discord-notifier"
  }
}

resource "aws_lambda_permission" "discord_notifier" {
  statement_id  = "AllowExecutionFromCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notifier.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.service["fastapi"].arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "batch_discord" {
  name            = "${local.name_prefix}-fastapi-batch-discord-filter"
  log_group_name  = aws_cloudwatch_log_group.service["fastapi"].name
  filter_pattern  = "?\"일반 문제 생성 끝\" ?\"모든 조합의 재고가 충분해\" ?\"채우지 못한 조합\" ?\"시도했지만 만들지 못함\" ?\"Spring 재고를 받지 못해\" ?\"생성 배치 단계 실패\" ?\"생성 배치를 시작하지 못함\" ?\"일반 문제 전송 끝\" ?\"전송 배치 단계 실패\" ?\"전송 배치를 시작하지 못함\" ?\"데일리 전송 실패\" ?\"배틀 전송 실패\" ?\"일반 문제 전송을 멈춤\" ?\"Spring이 거부한 문제\" ?\"전송 표시에 실패함\""
  destination_arn = aws_lambda_function.discord_notifier.arn

  depends_on = [
    aws_lambda_permission.discord_notifier,
  ]
}
