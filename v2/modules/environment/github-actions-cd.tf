locals {
  github_organization = {
    name = "100-hours-a-week"
    id   = "167328634"
  }

  github_stage_cd_repositories = var.environment == "stage" ? {
    fastapi = {
      name = "KTB4-9th-AI"
      id   = "1344703221"
    }
    spring = {
      name = "KTB4-9th-BE"
      id   = "1344700709"
    }
    judge = {
      name = "KTB4-9th-Judge"
      id   = "1374079744"
    }
    frontend = {
      name = "KTB4-9th-FE"
      id   = "1344701389"
    }
  } : {}

  github_stage_container_cd = var.environment == "stage" ? {
    fastapi = {
      ecr_arn              = var.ecr_repository_arns["fastapi"]
      task_definition_arns = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-fastapi:*"]
      service_arns         = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.main.name}/${local.name_prefix}-fastapi"]
      pass_role_arns = [
        aws_iam_role.application_execution["fastapi"].arn,
        aws_iam_role.application_task["fastapi"].arn,
      ]
    }
    spring = {
      ecr_arn              = var.ecr_repository_arns["spring"]
      task_definition_arns = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-spring:*"]
      service_arns         = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.main.name}/${local.name_prefix}-spring"]
      pass_role_arns = [
        aws_iam_role.application_execution["spring"].arn,
        aws_iam_role.application_task["spring"].arn,
      ]
    }
    judge = {
      ecr_arn = var.ecr_repository_arns["judge"]
      task_definition_arns = [
        "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-judge-api:*",
        "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-judge-worker:*",
      ]
      service_arns = [
        "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.main.name}/${local.name_prefix}-judge-api",
        "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.main.name}/${local.name_prefix}-judge-worker",
      ]
      pass_role_arns = [
        aws_iam_role.application_execution["judge-api"].arn,
        aws_iam_role.application_task["judge-api"].arn,
        aws_iam_role.worker_execution.arn,
        aws_iam_role.worker_task.arn,
      ]
    }
  } : {}

  github_stage_target_health_actions = ["elasticloadbalancing:DescribeTargetHealth"]
}

resource "aws_iam_role" "github_stage_cd" {
  for_each = local.github_stage_cd_repositories

  name = "${local.name_prefix}-github-${each.key}-cd"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_organization.name}@${local.github_organization.id}/${each.value.name}@${each.value.id}:environment:staging"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Repository = each.value.name
    Purpose    = "GitHubStageCD"
  })
}

resource "aws_iam_role_policy" "github_stage_container_cd" {
  for_each = local.github_stage_container_cd

  name = "deploy-own-ecs-service"
  role = aws_iam_role.github_stage_cd[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ResolveOwnImageDigest"
        Effect   = "Allow"
        Action   = ["ecr:DescribeImages"]
        Resource = each.value.ecr_arn
      },
      {
        Sid      = "ReadTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Sid      = "RegisterOwnTaskDefinitions"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = each.value.task_definition_arns
      },
      {
        Sid      = "UpdateOwnServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = each.value.service_arns
      },
      {
        Sid      = "ReadOwnTargetHealth"
        Effect   = "Allow"
        Action   = local.github_stage_target_health_actions
        Resource = "*"
      },
      {
        Sid      = "PassOwnTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = each.value.pass_role_arns
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "github_stage_frontend_cd" {
  for_each = var.environment == "stage" ? { frontend = true } : {}

  name = "deploy-stage-frontend"
  role = aws_iam_role.github_stage_cd[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListStageFrontendBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.frontend.arn
      },
      {
        Sid      = "SynchronizeStageFrontendObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.frontend.arn}/*"
      },
      {
        Sid      = "InvalidateStageFrontend"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = aws_cloudfront_distribution.frontend.arn
      },
    ]
  })
}
