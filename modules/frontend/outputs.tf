output "cloudfront_domain_name" {
  description = "Public URL your users actually visit."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "amplify_app_id" {
  description = "Needed if you connect a real git repo to this app via the console/CLI after apply."
  value       = aws_amplify_app.frontend.id
}
