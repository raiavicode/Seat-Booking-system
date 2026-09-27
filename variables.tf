variable "project_name" {
  description = "Short name used as a prefix for every resource this repo creates, e.g. \"seatbook\". Keep it short -- some AWS resource name length limits (e.g. DynamoDB table names, IAM role names) get hit fast once environment and resource-type suffixes are added on top."
  type        = string
  default     = "seatbook"
}

variable "environment" {
  description = "Deployment environment, e.g. \"dev\", \"staging\", \"prod\". Deploy this repo multiple times with different values (and a different backend state key -- see backend.tf.example) to get fully isolated environments."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into. Note: CloudFront itself is global, but the ACM certificate for a custom domain (see modules/frontend) must be requested in us-east-1 specifically regardless of this value -- that's an AWS/CloudFront constraint, not something this variable controls."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags applied to every resource in every module via the provider's default_tags block."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "seat-booking-reference-architecture"
  }
}

# ---- Networking (BYO VPC) ----
# This repo does not create a VPC for you -- ElastiCache and the
# Process Payment Lambda need to live inside one, but VPC design
# (how many AZs, NAT strategy, existing peering/Transit Gateway
# setups) is usually something an org already has opinions about.
# Point these at an EXISTING VPC's private subnets.

variable "vpc_id" {
  description = "Existing VPC ID. Must have at least 2 private subnets for high availability."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (at least 2, in different AZs) for ElastiCache and the Process Payment Lambda. IMPORTANT: these subnets need a route to the internet (typically via a NAT Gateway) for Process Payment to reach an external payment gateway's API -- a fully isolated private subnet with no NAT will cause every payment to fail with a timeout. This repo does not create a NAT Gateway for you; see the README troubleshooting section."
  type        = list(string)
}

# ---- Application-specific config ----

variable "ses_sender_address" {
  description = "Email address booking confirmations are sent from. You must click the verification link SES emails to this address after the first apply, or sending will fail."
  type        = string
}

variable "lock_ttl_seconds" {
  description = "How long a PENDING lock is honored before the Arrow-21 timeout sweep considers it abandoned and releases it."
  type        = number
  default     = 600
}

variable "alarm_sns_topic_arn" {
  description = "Optional: an existing SNS topic (e.g. wired to Slack or PagerDuty) that CloudWatch alarms notify. Leave blank to create alarms with no action."
  type        = string
  default     = ""
}
