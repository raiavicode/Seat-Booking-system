variable "project_name" {
  description = "Short project name used as a prefix for all resource names (e.g. \"seatbook\")."
  type        = string
}

variable "environment" {
  description = "Deployment environment suffix, e.g. \"dev\", \"staging\", \"prod\". Keeps table names unique per environment when deployed into the same account."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource in this module. Passed down from the root module so tagging stays consistent project-wide."
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt table data at rest."
  type        = string
}
