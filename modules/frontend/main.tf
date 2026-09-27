############################################################
# MODULE: frontend
#
# WHAT THIS IS:
#   Arrows 1-2 origin here: CloudFront serves the static frontend,
#   which uses the Amplify JS SDK to talk to Cognito for auth.
#
# SCOPE NOTE: Amplify Hosting is normally connected directly to a
# git repo through the AWS console/CLI for its build+deploy
# pipeline -- the Terraform AWS provider's Amplify resources can
# declare the app and branch, but the actual first deployment
# still needs to be triggered once outside Terraform (console,
# CLI, or CI). This module sets up the App + branch + CloudFront
# distribution in front of it; connecting your actual repo is a
# manual one-time step documented in the root README.
############################################################

resource "aws_amplify_app" "frontend" {
  name = "${var.project_name}-frontend-${var.environment}"

  # Injected into the frontend build so it knows which API/user
  # pool to talk to without hardcoding environment-specific
  # values into the source code itself.
  environment_variables = {
    API_INVOKE_URL       = var.api_invoke_url
    COGNITO_USER_POOL_ID = var.cognito_user_pool_id
    COGNITO_CLIENT_ID    = var.cognito_client_id
  }

  tags = var.tags
}

resource "aws_amplify_branch" "main" {
  app_id      = aws_amplify_app.frontend.id
  branch_name = var.git_branch
  # Rebuilds automatically on every push to this branch once
  # you've connected a real repo (see the scope note above).
  enable_auto_build = true
}

# CloudFront in front of Amplify's own domain -- gives you a
# custom domain option and a single place to attach WAF rules
# later if you need them, rather than pointing DNS straight at
# Amplify's default hosting domain.
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name = "${aws_amplify_branch.main.branch_name}.${aws_amplify_app.frontend.default_domain}"
    origin_id   = "amplify-frontend"

    custom_origin_config {
      origin_protocol_policy = "https-only"
      http_port              = 80
      https_port             = 443
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "amplify-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods         = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]

    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

    forwarded_values {
      query_string = true
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # Using CloudFront's default certificate for simplicity -- if
    # you attach a custom domain, replace this block with an ACM
    # certificate ARN (must be in us-east-1 regardless of which
    # region the rest of this stack runs in; that's a CloudFront
    # requirement, not a choice this repo makes).
    cloudfront_default_certificate = true
  }

  # WAFv2 Web ACL, created in the root module with the us-east-1
  # aliased provider (a hard CloudFront requirement) and passed in
  # here -- kept as a root-level resource rather than created inside
  # this module so the module itself doesn't need to know about
  # provider aliasing, which is a root-module-only concern in
  # Terraform.
  web_acl_id = var.web_acl_id

  tags = merge(var.tags, { ArchitectureArrows = "1" })
}

# Standard security headers on every response -- HSTS, no-sniff,
# frame-deny (clickjacking protection), and a conservative referrer
# policy. This is the kind of hardening that costs nothing but is easy
# to forget on a "just get it deployed" frontend.
resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "${var.project_name}-security-headers-${var.environment}"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000 # 2 years -- standard HSTS preload-eligible duration
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}
