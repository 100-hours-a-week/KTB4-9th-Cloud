resource "aws_service_discovery_http_namespace" "main" {
  name        = "${var.environment}.cosmos-v2.local"
  description = "COSMOS v2 ${var.environment} Service Connect namespace"

  tags = { Name = "${var.environment}.cosmos-v2.local" }
}

