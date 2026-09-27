output "frontend_url" {
  description = "Where to actually open the app after apply."
  value       = "https://${module.frontend.cloudfront_domain_name}"
}

output "api_invoke_url" {
  value = module.api_gateway.invoke_url
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "state_machine_arn" {
  value = module.step_functions.state_machine_arn
}

output "dashboard_url" {
  description = "Direct link to the CloudWatch dashboard covering the reliability-critical metrics."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.observability.dashboard_name}"
}

output "post_apply_reminders" {
  description = "Manual steps Terraform cannot do for you -- see README for full detail."
  value = join("\n", [
    "1. Check the inbox for ${var.ses_sender_address} and click SES's verification link, or emails will silently fail to send.",
    "2. Replace the placeholder value in the payment-gateway secret (see modules/secrets) with your real API key via the AWS CLI or console.",
    "3. Connect a real git repository to the Amplify app (id in module.frontend output) via the AWS console if you haven't already.",
  ])
}
