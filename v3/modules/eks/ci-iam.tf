# 이미지 승격 워크플로는 기존 ECR에서 읽어 서비스별 ECR로 복사만 한다.
# EKS, Argo CD, Secret, ECS 권한은 주지 않는다.
data "aws_ecr_repository" "promote_source" {
  for_each = var.ci_promote_images

  name = each.key
}

data "aws_iam_policy_document" "ci_promote_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [var.ci_promote_sub]
    }
  }
}

data "aws_iam_policy_document" "ci_promote" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for repo in data.aws_ecr_repository.promote_source : repo.arn]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for name in flatten(values(var.ci_promote_images)) : aws_ecr_repository.service[name].arn]
  }
}

resource "aws_iam_role" "ci_promote" {
  name               = "${var.cluster_name}-ci-promote"
  assume_role_policy = data.aws_iam_policy_document.ci_promote_assume.json
}

resource "aws_iam_role_policy" "ci_promote" {
  name   = "ecr-promote"
  role   = aws_iam_role.ci_promote.id
  policy = data.aws_iam_policy_document.ci_promote.json
}

output "ci_promote_role_arn" { value = aws_iam_role.ci_promote.arn }
