output "invoke_url" {
  description = "Base URL the frontend calls to hit this API -- feed this into the frontend module / Amplify environment config."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "stage_arn" {
  description = "ARN of the deployed stage -- needed by the root module to associate the regional WAFv2 Web ACL with this API."
  value       = aws_api_gateway_stage.this.arn
}
