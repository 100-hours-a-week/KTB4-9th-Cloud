locals {
  image_updater_ecr_repositories = toset([
    "cosmos-v2/spring",
    "cosmos-v2/fastapi",
  ])
}

data "aws_ecr_repository" "image_updater" {
  for_each = local.image_updater_ecr_repositories

  name = each.key
}

data "aws_iam_policy_document" "image_updater_ecr" {
  statement {
    sid       = "ECRAuthentication"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "ReadApprovedImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]
    resources = [for repository in data.aws_ecr_repository.image_updater : repository.arn]
  }
}

resource "aws_iam_role" "image_updater" {
  name               = "${var.cluster_name}-argocd-image-updater-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "image_updater_ecr" {
  name   = "read-approved-ecr-images"
  role   = aws_iam_role.image_updater.id
  policy = data.aws_iam_policy_document.image_updater_ecr.json
}

resource "aws_eks_pod_identity_association" "image_updater" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "argocd"
  service_account = "argocd-image-updater"
  role_arn        = aws_iam_role.image_updater.arn
}
