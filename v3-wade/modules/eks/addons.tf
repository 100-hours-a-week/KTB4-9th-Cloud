locals {
  system_placement = {
    nodeSelector = { "workload-class" = "system" }
    tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
  }
}

# 노드가 Ready가 되려면 CNI가 필요하므로 노드 그룹보다 먼저 설치한다.
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({ enableNetworkPolicy = "true" })

  pod_identity_association {
    role_arn        = aws_iam_role.vpc_cni.arn
    service_account = "aws-node"
  }

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  configuration_values = jsonencode(local.system_placement)

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  configuration_values = jsonencode({ controller = local.system_placement })

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"

  configuration_values = jsonencode(local.system_placement)

  depends_on = [aws_eks_node_group.main]
}
