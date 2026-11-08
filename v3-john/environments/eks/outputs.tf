output "cluster_name" { value = module.eks.cluster_name }
output "vpc_id" { value = module.network.vpc_id }
output "mysql_address" { value = module.data.mysql_address }
output "edge_bucket" { value = var.enable_edge ? module.edge[0].bucket : null }
output "edge_distribution_id" { value = var.enable_edge ? module.edge[0].distribution_id : null }
