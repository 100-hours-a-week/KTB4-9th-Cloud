variable "domain_name" {
  description = "Route 53 Root Domain Name"
  type        = string
  default     = "cosmoscode.site"
}

variable "mlflow_hostname" {
  description = "MLflow service hostname"
  type        = string
  default     = "mlflow.cosmoscode.site"
}

variable "mlflow_image" {
  description = "MLflow container image"
  type        = string
  default     = "ghcr.io/mlflow/mlflow:v2.16.0"
}

variable "mlflow_cpu" {
  description = "MLflow Fargate task CPU"
  type        = number
  default     = 512
}

variable "mlflow_memory" {
  description = "MLflow Fargate task Memory (MB)"
  type        = number
  default     = 1024
}

variable "mlflow_desired_count" {
  description = "MLflow Fargate service desired task count"
  type        = number
  default     = 1
}

variable "alb_rule_priority" {
  description = "ALB listener rule priority for MLflow host routing"
  type        = number
  default     = 130
}
