variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- From root main.tf ----
variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt each function's environment variables."
  type        = string
}
variable "lambda_execution_role_arn" {
  description = "ARN of the shared Lambda execution role (from the iam module)."
  type        = string
}

variable "lambda_execution_role_name" {
  description = "Name of the shared Lambda execution role, used to attach per-function policies."
  type        = string
}

# ---- From the dynamodb module ----
variable "slots_table_name" {
  type = string
}

variable "slots_read_write_policy_arn" {
  type = string
}

variable "lock_ttl_seconds" {
  description = "How long a PENDING lock is valid before it's considered abandoned. Must match the value the EventBridge timeout rule (Arrow 21) uses."
  type        = number
  default     = 600
}

# ---- From the secrets module ----
variable "payment_gateway_secret_arn" {
  type = string
}

variable "payment_secret_read_policy_arn" {
  type = string
}

# ---- From the elasticache module ----
variable "cache_endpoint" {
  type = string
}

variable "private_subnet_ids" {
  description = "Needed because Process Payment runs inside the VPC to reach ElastiCache."
  type        = list(string)
}

variable "lambda_security_group_id" {
  type = string
}

# ---- From the async-notifications module ----
variable "ses_sender_address" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

variable "notify_permissions_policy_arn" {
  description = "IAM policy granting ses:SendEmail and sns:Publish, scoped to this project's resources."
  type        = string
}

variable "sqs_consume_policy_arn" {
  description = "IAM policy granting sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes on the notifications queue -- required for the event_source_mapping (wired in the root module) to actually deliver messages to the Notify Lambda."
  type        = string
}
