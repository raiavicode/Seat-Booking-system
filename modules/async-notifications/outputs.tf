output "notifications_queue_arn" {
  description = "SQS queue ARN. The ROOT module uses this plus the Notify Lambda's ARN (from lambda-functions) to create the event_source_mapping that actually delivers messages -- see root main.tf."
  value       = aws_sqs_queue.notifications.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.booking_events.arn
}

output "ses_sender_address" {
  value = aws_ses_email_identity.sender.email
}

output "notify_permissions_policy_arn" {
  value = aws_iam_policy.notify_permissions.arn
}

output "sqs_consume_policy_arn" {
  value = aws_iam_policy.sqs_consume.arn
}

output "lock_timeout_rule_name" {
  description = "Name of the EventBridge schedule rule. The ROOT module attaches Release Lock as this rule's target -- see root main.tf."
  value       = aws_cloudwatch_event_rule.lock_timeout_sweep.name
}

output "lock_timeout_rule_arn" {
  value = aws_cloudwatch_event_rule.lock_timeout_sweep.arn
}
