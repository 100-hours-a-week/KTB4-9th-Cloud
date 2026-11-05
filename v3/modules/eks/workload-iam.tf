# 전환 기간에는 ECS가 쓰는 기존 Secret을 읽기 전용으로 공유한다.
data "aws_secretsmanager_secret" "workload" {
  for_each = toset(flatten(values(var.workload_secrets)))

  name = each.key
}

data "aws_iam_policy_document" "workload_secrets" {
  for_each = var.workload_secrets

  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for name in each.value : data.aws_secretsmanager_secret.workload[name].arn]
  }
}

resource "aws_iam_role" "workload" {
  for_each = var.workload_secrets

  name               = "${var.cluster_name}-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "workload_secrets" {
  for_each = var.workload_secrets

  name   = "read-secrets"
  role   = aws_iam_role.workload[each.key].id
  policy = data.aws_iam_policy_document.workload_secrets[each.key].json
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = var.workload_secrets

  cluster_name    = aws_eks_cluster.main.name
  namespace       = "prod"
  service_account = each.key
  role_arn        = aws_iam_role.workload[each.key].arn
}

data "aws_iam_policy_document" "mlflow_s3" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [var.mlflow_bucket_arn, "${var.mlflow_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "mlflow_s3" {
  name   = "mlflow-artifacts"
  role   = aws_iam_role.workload["mlflow-sa"].id
  policy = data.aws_iam_policy_document.mlflow_s3.json
}
