output "lambda_execution_role_name" {
  description = "Name of the shared Lambda execution role. Other modules attach their own scoped policies to this role by name."
  value       = aws_iam_role.lambda_execution.name
}

output "lambda_execution_role_arn" {
  description = "ARN of the shared Lambda execution role. Passed to every aws_lambda_function resource's `role` argument."
  value       = aws_iam_role.lambda_execution.arn
}
