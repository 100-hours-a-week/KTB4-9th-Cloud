variable "domain" { type = string }
variable "zone_id" { type = string }
variable "nlb_arn" { type = string }
variable "nlb_dns_name" { type = string }
variable "allowed_cidrs" { type = list(string) }
