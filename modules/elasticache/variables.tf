variable "project_name" {
  description = "Short project name used as a prefix for all resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment suffix."
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the cache into. This architecture assumes Lambdas run inside a VPC to reach ElastiCache -- see root module README for the VPC setup this expects."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the cache subnet group. Use private subnets, not public ones -- this cache should never be internet-reachable."
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID attached to the booking Lambdas, so the cache's security group can allow inbound access from exactly that group and nothing else."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
