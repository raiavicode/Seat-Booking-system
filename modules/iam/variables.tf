variable "project_name" {
  description = "Short project name used as a prefix for all resource names."
  type        = string
}

variable "environment" {
  description = "Deployment environment suffix, e.g. \"dev\", \"staging\", \"prod\"."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt Lambda environment variables -- the execution role needs Decrypt permission on it."
  type        = string
}
