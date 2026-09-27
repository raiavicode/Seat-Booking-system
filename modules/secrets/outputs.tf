output "secret_arn" {
  description = "ARN of the payment gateway secret, passed to the Process Payment Lambda as an environment variable so it knows which secret to fetch."
  value       = aws_secretsmanager_secret.payment_gateway.arn
}

output "secret_name" {
  description = "Name of the payment gateway secret."
  value       = aws_secretsmanager_secret.payment_gateway.name
}

output "read_policy_arn" {
  description = "ARN of the IAM policy granting read access to just this secret."
  value       = aws_iam_policy.payment_gateway_read.arn
}
