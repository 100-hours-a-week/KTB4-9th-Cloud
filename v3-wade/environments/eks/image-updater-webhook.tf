locals {
  image_updater_webhook_domain      = "image-updater-wade.cosmoscode.site"
  image_updater_webhook_secret_name = "cosmos/wade/argocd-image-updater-webhook"
}

resource "random_password" "image_updater_webhook" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "image_updater_webhook" {
  name                    = local.image_updater_webhook_secret_name
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "image_updater_webhook" {
  secret_id = aws_secretsmanager_secret.image_updater_webhook.id
  secret_string = jsonencode({
    secret = random_password.image_updater_webhook.result
  })
}

resource "aws_cloudwatch_event_connection" "image_updater_webhook" {
  count = var.enable_edge ? 1 : 0

  name               = "${local.name}-image-updater-webhook"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "X-Webhook-Secret"
      value = random_password.image_updater_webhook.result
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "image_updater_webhook" {
  count = var.enable_edge ? 1 : 0

  name                             = "${local.name}-image-updater-webhook"
  invocation_endpoint              = "https://${local.image_updater_webhook_domain}/webhook?type=cloudevents"
  http_method                      = "POST"
  invocation_rate_limit_per_second = 5
  connection_arn                   = aws_cloudwatch_event_connection.image_updater_webhook[0].arn

  depends_on = [module.edge_image_updater_webhook]
}

resource "aws_cloudwatch_event_rule" "approved_image" {
  count = var.enable_edge ? 1 : 0

  name = "${local.name}-approved-image"
  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]
    detail = {
      action-type     = ["PUSH"]
      result          = ["SUCCESS"]
      repository-name = ["cosmos-v2/spring", "cosmos-v2/fastapi"]
      image-tag       = [{ prefix = "approved-" }]
    }
  })
}

data "aws_iam_policy_document" "eventbridge_image_updater_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge_image_updater" {
  count = var.enable_edge ? 1 : 0

  name               = "${local.name}-eventbridge-image-updater"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_image_updater_assume.json
}

data "aws_iam_policy_document" "eventbridge_image_updater" {
  count = var.enable_edge ? 1 : 0

  statement {
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.image_updater_webhook[0].arn]
  }
}

resource "aws_iam_role_policy" "eventbridge_image_updater" {
  count = var.enable_edge ? 1 : 0

  name   = "invoke-image-updater-webhook"
  role   = aws_iam_role.eventbridge_image_updater[0].id
  policy = data.aws_iam_policy_document.eventbridge_image_updater[0].json
}

resource "aws_cloudwatch_event_target" "image_updater_webhook" {
  count = var.enable_edge ? 1 : 0

  rule     = aws_cloudwatch_event_rule.approved_image[0].name
  arn      = aws_cloudwatch_event_api_destination.image_updater_webhook[0].arn
  role_arn = aws_iam_role.eventbridge_image_updater[0].arn

  input_transformer {
    input_paths = {
      account = "$.account"
      digest  = "$.detail.image-digest"
      id      = "$.id"
      region  = "$.region"
      repo    = "$.detail.repository-name"
      tag     = "$.detail.image-tag"
      time    = "$.time"
    }
    input_template = <<-JSON
      {
        "specversion": "1.0",
        "id": "<id>",
        "type": "com.amazon.ecr.image.push",
        "source": "urn:aws:ecr:<region>:<account>:repository/<repo>",
        "subject": "<repo>:<tag>",
        "time": "<time>",
        "datacontenttype": "application/json",
        "data": {
          "repositoryName": "<repo>",
          "imageDigest": "<digest>",
          "imageTag": "<tag>",
          "registryId": "<account>"
        }
      }
    JSON
  }
}
