resource "aws_kms_key" "secrets" {
  description             = "${var.cluster_name} Kubernetes Secret 암호화"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# 컨트롤 플레인 로그 그룹을 먼저 만들어 보존 기간을 고정한다.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = [for subnet in aws_subnet.eks : subnet.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
    aws_route_table_association.eks,
  ]
}
