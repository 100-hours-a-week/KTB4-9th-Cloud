variable "cluster_name" {
  type    = string
  default = "cosmos-v3-john"
}

variable "kubernetes_version" {
  type    = string
  default = "1.37"
}

variable "vpc_id" {
  type = string
}

variable "private_route_table_ids" {
  description = "Private Route Table. 키는 AZ 접미사(a, c)"
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
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    labels         = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {
    system-ng = {
      instance_types = ["t3.large", "t3a.large"]
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      labels         = { "workload-class" = "system" }
      taints         = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    stateful-ng = {
      instance_types = ["m7i.large", "m6i.large", "m5.large", "m5a.large", "r5.large", "r6i.large", "t3.large", "t3a.large"]
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      labels         = { "workload-class" = "stateful" }
      taints         = [{ key = "workload", value = "stateful", effect = "NO_SCHEDULE" }]
    }
    judge-base-ng = {
      instance_types = ["c7i.xlarge", "c6i.xlarge", "c5.xlarge"]
      min_size       = 1
      desired_size   = 1
      max_size       = 1
      labels         = { "workload-class" = "judge" }
      taints         = [{ key = "workload", value = "judge", effect = "NO_SCHEDULE" }]
    }
    application-ng = {
      instance_types = ["t3.xlarge", "t3a.xlarge", "m5.xlarge"]
      min_size       = 2
      desired_size   = 2
      max_size       = 2
      labels         = { "workload-class" = "application" }
      taints         = []
    }
  }
}

variable "workload_secrets" {
  description = "prod ServiceAccount별 읽기 허용 Secret"
  type        = map(list(string))
}

variable "mlflow_bucket_arn" {
  type = string
}

