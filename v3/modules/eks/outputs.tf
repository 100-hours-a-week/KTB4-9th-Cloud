output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "subnet_ids" { value = { for key, subnet in aws_subnet.eks : key => subnet.id } }
output "node_role_arn" { value = aws_iam_role.node.arn }
