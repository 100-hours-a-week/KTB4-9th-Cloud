locals {
  github_organization = {
    name = "100-hours-a-week"
    id   = "167328634"
  }

  github_stage_ci_repositories = {
    spring = {
      name = "KTB4-9th-BE"
      id   = "1344700709"
    }
    fastapi = {
      name = "KTB4-9th-AI"
      id   = "1344703221"
    }
    judge = {
      name = "KTB4-9th-Judge"
      id   = "1374079744"
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998"]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-github-actions"
  })
}

resource "aws_iam_role" "github_stage_ci" {
  for_each = local.github_stage_ci_repositories

  name = "${var.project_name}-github-stage-${each.key}-ci"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRoleWithWebIdentity"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_organization.name}@${local.github_organization.id}/${each.value.name}@${each.value.id}:environment:staging-ci"
        }
      }
    }]
  })

  tags = merge(local.common_tags, {
    Service = each.key
    Purpose = "GitHubStageCI"
  })
}

resource "aws_iam_role_policy" "github_stage_ecr" {
  for_each = local.github_stage_ci_repositories

  name = "push-own-ecr-repository"
  role = aws_iam_role.github_stage_ci[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthentication"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushOwnRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.service[each.key].arn
      },
    ]
  })
}
