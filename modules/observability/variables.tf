variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "release_lock_function_name" {
  type = string
}

variable "notifications_queue_name" {
  type = string
}

variable "state_machine_arn" {
  type = string
}

variable "alarm_sns_topic_arn" {
  description = "Where alarm notifications go (e.g. an ops Slack channel via SNS or PagerDuty integration). Leave as empty string to create alarms without any action -- they'll still show red in the console/dashboard, just won't page anyone."
  type        = string
  default     = ""
}
