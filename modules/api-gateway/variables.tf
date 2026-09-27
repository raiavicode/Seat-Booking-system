variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  description = "Used to construct the StartSyncExecution service integration URI, which is region-specific."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the API access log group."
  type        = string
}

variable "cognito_user_pool_arn" {
  type = string
}

variable "state_machine_arn" {
  type = string
}
