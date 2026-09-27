output "user_pool_id" {
  description = "Cognito User Pool ID. Needed by API Gateway to configure the Cognito authorizer."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN. This is what API Gateway's COGNITO_USER_POOLS authorizer actually references."
  value       = aws_cognito_user_pool.this.arn
}

output "user_pool_client_id" {
  description = "App client ID. Your frontend (Amplify config) needs this to initiate login."
  value       = aws_cognito_user_pool_client.app.id
}

output "identity_pool_id" {
  description = "Identity Pool ID, if the frontend needs direct temporary AWS credentials."
  value       = aws_cognito_identity_pool.this.id
}
