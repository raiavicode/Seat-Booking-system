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

variable "slots_table_stream_arn" {
  description = "DynamoDB Streams ARN from the dynamodb module. This is the SOURCE of the Arrow-15 pipe -- without it, this module has nothing to read from."
  type        = string
}

variable "ses_sender_address" {
  description = "Email address that booking confirmations are sent FROM. Must be an address/domain you control -- SES will email it a verification link after apply, and won't send anything through it until that link is clicked."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the SQS queues and SNS topic in this module."
  type        = string
}
