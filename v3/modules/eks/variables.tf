variable "cluster_name" {
  type    = string
  default = "cosmos-v3"
}

variable "kubernetes_version" {
  type    = string
  default = "1.37"
}

variable "vpc_id" {
  type = string
}

variable "private_route_table_ids" {
  description = "v2 Shared의 Private Route Table. 키는 AZ 접미사(a, c)"
  type        = map(string)
}

variable "subnets" {
  description = "EKS 전용 Private 서브넷. 노드는 a에만 배치하고 c는 컨트롤 플레인의 2개 AZ 요건용"
  type = map(object({
    availability_zone = string
    cidr_block        = string
  }))
  default = {
    a = { availability_zone = "ap-northeast-2a", cidr_block = "10.20.32.0/20" }
    c = { availability_zone = "ap-northeast-2c", cidr_block = "10.20.48.0/20" }
  }
}

variable "service_cidr" {
  type    = string
  default = "172.20.0.0/16"
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "node_groups" {
  type = map(object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
    labels        = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {
    system-ng = {
      instance_type = "t3.large"
      min_size      = 2
      desired_size  = 2
      max_size      = 3
      labels        = { "workload-class" = "system" }
      taints        = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    application-ng = {
      instance_type = "t3.xlarge"
      min_size      = 2
      desired_size  = 2
      max_size      = 6
      labels        = { "workload-class" = "application" }
      taints        = []
    }
  }
}

variable "ecr_repositories" {
  type = list(string)
  default = [
    "cosmos-auth",
    "cosmos-core",
    "cosmos-battle",
    "cosmos-ai-llm",
    "cosmos-ai-make-problem",
    "cosmos-ai-problem-batch",
    "cosmos-judge-api",
    "cosmos-judge-worker",
    "cosmos-mlflow",
  ]
}
