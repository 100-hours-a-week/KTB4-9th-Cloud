output "mlflow_url" {
  description = "MLflow Tracking Server HTTPS URL"
  value       = "https://${var.mlflow_hostname}"
}

output "mlflow_s3_bucket" {
  description = "MLflow Artifacts S3 Bucket Name"
  value       = aws_s3_bucket.mlflow_artifacts.id
}

output "mlflow_target_group_arn" {
  description = "MLflow ALB Target Group ARN"
  value       = aws_lb_target_group.mlflow.arn
}

output "mlflow_ecs_service_name" {
  description = "MLflow ECS Service Name"
  value       = aws_ecs_service.mlflow.name
}

output "mlflow_database_uri" {
  description = "MLflow Backend Database URI pattern"
  value       = "postgresql://cosmos_ai:****@ai-postgres:5432/mlflow"
}
