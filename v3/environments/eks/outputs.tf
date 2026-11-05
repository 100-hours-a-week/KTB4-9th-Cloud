output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "eks_subnet_ids" { value = module.eks.subnet_ids }
output "node_role_arn" { value = module.eks.node_role_arn }
