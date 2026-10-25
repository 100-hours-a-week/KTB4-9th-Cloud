variable "enable_stateful_services" {
  description = "AI PostgreSQL과 Judge PostgreSQL/Redis ECS service 활성화 여부"
  type        = bool
  default     = false
}

variable "ai_postgres_image" {
  description = "@sha256으로 고정한 PostgreSQL 17+pgvector image reference"
  type        = string
  default     = null
  nullable    = true
}

variable "judge_postgres_image" {
  description = "@sha256으로 고정한 Judge PostgreSQL 공식 image reference"
  type        = string
  default     = null
  nullable    = true
}

variable "judge_redis_image" {
  description = "@sha256으로 고정한 Judge Valkey/Redis 공식 image reference"
  type        = string
  default     = null
  nullable    = true
}

variable "enable_phase2_services" {
  description = "Spring/FastAPI/Judge API Fargate service 활성화 여부"
  type        = bool
  default     = false
}

variable "spring_image_digest" {
  description = "검증된 Spring sha256 digest"
  type        = string
  default     = null
  nullable    = true
}

variable "fastapi_image_digest" {
  description = "검증된 FastAPI sha256 digest"
  type        = string
  default     = null
  nullable    = true
}

variable "judge_image_digest" {
  description = "Judge API와 Worker가 공유하는 검증된 sha256 digest"
  type        = string
  default     = null
  nullable    = true
}

variable "judge_api_command" {
  description = "공용 Judge image에서 API를 실행할 command"
  type        = list(string)
  default     = ["./scripts/server"]
}

variable "judge_worker_command" {
  description = "공용 Judge image에서 Worker를 실행할 command"
  type        = list(string)
  default     = ["./scripts/workers"]
}

variable "enable_judge_worker_capacity" {
  description = "Judge Worker EC2 capacity provider 활성화 여부"
  type        = bool
  default     = false
}

variable "enable_judge_worker" {
  description = "Judge Worker ECS service 활성화 여부"
  type        = bool
  default     = false
}

variable "judge_worker_desired_count" {
  description = "Judge Worker desired task 수"
  type        = number
  default     = 1
}

variable "enable_public_dns_cutover" {
  description = "Stage V2 CloudFront가 apex 및 www 도메인을 소유할지 여부"
  type        = bool
  default     = false
}

variable "discord_webhook_url" {
  description = "Discord incoming webhook URL for batch monitoring notifications"
  type        = string
  default     = ""
  sensitive   = true
}

