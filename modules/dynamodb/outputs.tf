# These outputs are how other modules (lambda-functions, step-functions,
# async-notifications) wire themselves to this table without hardcoding
# its name or ARN -- Terraform resolves the real values at apply time.

output "table_name" {
  description = "Name of the slots table, needed by Lambda environment variables."
  value       = aws_dynamodb_table.slots.name
}

output "table_arn" {
  description = "ARN of the slots table, needed anywhere an IAM policy needs to reference it directly."
  value       = aws_dynamodb_table.slots.arn
}

output "stream_arn" {
  description = "ARN of the DynamoDB Stream. The async-notifications module attaches this as an event source to the Notify Lambda -- this is the literal wiring behind Arrow 15 (DynamoDB Streams -> SQS)."
  value       = aws_dynamodb_table.slots.stream_arn
}

output "read_write_policy_arn" {
  description = "ARN of the IAM policy granting read/write access to this table. Attach this to any Lambda execution role that needs to touch slot data."
  value       = aws_iam_policy.slots_rw.arn
}
