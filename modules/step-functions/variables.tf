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

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the Step Functions execution log group."
  type        = string
}

variable "lock_slot_function_arn" {
  type = string
}

variable "process_payment_function_arn" {
  type = string
}

variable "release_lock_function_arn" {
  type = string
}
