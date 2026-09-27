############################################################
# ROOT MODULE
#
# This file is the closest thing to "the diagram, in code." Module
# calls below are ordered to match the 7 build phases in the PDF
# guide (Client/Auth -> Edge/API -> Orchestration -> Data Layer ->
# Async Notifications -> Saga Compensation -> Observability), even
# though Terraform itself resolves the real dependency graph from
# references, not from the order things are written in this file.
#
# WHY TWO RESOURCES LIVE HERE INSTEAD OF INSIDE A MODULE:
# The SQS -> Notify event_source_mapping and the EventBridge ->
# Release Lock target/permission each need outputs from TWO
# modules that don't otherwise depend on each other (async-
# notifications and lambda-functions). Putting either resource
# inside one of those modules would force that module to take the
# other module's Lambda ARN as an input it doesn't otherwise need,
# creating an awkward, easy-to-miss circular reference the first
# time someone tries to refactor either module in isolation.
# Keeping "final wiring between independently-built pieces" at the
# root is a deliberate structural choice, not an oversight.
############################################################

# ---- Phase 1: Foundational (no dependencies on other modules) ----

data "aws_caller_identity" "current" {}

# Shared customer-managed KMS key: used to encrypt the payment-gateway
# secret, Lambda environment variables, DynamoDB, SQS, SNS, and log
# groups. Using one CMK for all of these (rather than AWS-owned default
# keys) gives you actual key-level access control and an audit trail
# (CloudTrail logs every Decrypt call) for the pieces of this system
# that touch payment credentials.
resource "aws_kms_key" "app" {
  description             = "${var.project_name}-${var.environment} CMK for secrets, Lambda env vars, and log encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  tags                    = var.tags

  # Two statements: (1) the standard "account root has full access via
  # IAM policies" grant -- without this, you can permanently lock
  # yourself out of your own key, since IAM policies alone can't grant
  # access unless the key policy allows it; (2) explicit permission for
  # CloudWatch Logs to use this key, scoped to log groups in this
  # account -- required for the encrypted log groups in this repo
  # (Step Functions, API Gateway access logs) to actually work, since
  # CloudWatch Logs needs its own grant on a customer-managed key,
  # unlike the AWS-owned default key.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsEncryption"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "app" {
  name          = "alias/${var.project_name}-${var.environment}"
  target_key_id = aws_kms_key.app.key_id
}

module "iam" {
  source       = "./modules/iam"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn
}

module "secrets" {
  source       = "./modules/secrets"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn
}

module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn
}

module "cognito" {
  source       = "./modules/cognito"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
}

# ---- Phase 2: Data layer that needs networking ----

# NOTE: this repo does not manage a Lambda security group as a
# standalone concern -- Process Payment's own security group is
# created inline via its VPC config needing one. To keep this
# root file straightforward, we create ONE shared security group
# here for any Lambda that needs VPC access, and pass it to both
# elasticache (as the allowed ingress source) and lambda-functions
# (as what Process Payment launches into).
resource "aws_security_group" "lambda_vpc" {
  name        = "${var.project_name}-lambda-vpc-${var.environment}"
  description = "Attached to any Lambda that runs inside the VPC (currently just Process Payment)"
  vpc_id      = var.vpc_id

  # Rules declared separately below -- see the comment in
  # modules/elasticache/main.tf on aws_security_group.cache for why
  # (this SG and the cache SG reference each other, which would be
  # circular as inline blocks).

  tags = var.tags
}

resource "aws_security_group_rule" "lambda_vpc_egress_https" {
  type              = "egress"
  description       = "HTTPS to the internet (via NAT) for the external payment gateway API"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.lambda_vpc.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "lambda_vpc_egress_redis" {
  type                     = "egress"
  description              = "Redis to the cache cluster"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda_vpc.id
  source_security_group_id = module.elasticache.cache_security_group_id
}

module "elasticache" {
  source                    = "./modules/elasticache"
  project_name              = var.project_name
  environment               = var.environment
  tags                      = var.tags
  vpc_id                    = var.vpc_id
  private_subnet_ids        = var.private_subnet_ids
  lambda_security_group_id  = aws_security_group.lambda_vpc.id
}

# ---- Phase 3: Async notification plumbing (needs the DynamoDB stream) ----

module "async_notifications" {
  source                  = "./modules/async-notifications"
  project_name            = var.project_name
  environment             = var.environment
  tags                    = var.tags
  slots_table_stream_arn  = module.dynamodb.stream_arn
  ses_sender_address      = var.ses_sender_address
  kms_key_arn             = aws_kms_key.app.arn
}

# ---- Phase 4: The five Lambda functions ----

module "lambda_functions" {
  source       = "./modules/lambda-functions"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn

  lambda_execution_role_arn  = module.iam.lambda_execution_role_arn
  lambda_execution_role_name = module.iam.lambda_execution_role_name

  slots_table_name             = module.dynamodb.table_name
  slots_read_write_policy_arn  = module.dynamodb.read_write_policy_arn
  lock_ttl_seconds             = var.lock_ttl_seconds

  payment_gateway_secret_arn     = module.secrets.secret_arn
  payment_secret_read_policy_arn = module.secrets.read_policy_arn

  cache_endpoint            = module.elasticache.cache_endpoint
  private_subnet_ids        = var.private_subnet_ids
  lambda_security_group_id  = aws_security_group.lambda_vpc.id

  ses_sender_address              = module.async_notifications.ses_sender_address
  sns_topic_arn                   = module.async_notifications.sns_topic_arn
  notify_permissions_policy_arn   = module.async_notifications.notify_permissions_policy_arn
  sqs_consume_policy_arn          = module.async_notifications.sqs_consume_policy_arn
}

# ---- Phase 5: The saga orchestrator ----

module "step_functions" {
  source       = "./modules/step-functions"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn

  lock_slot_function_arn        = module.lambda_functions.lock_slot_function_arn
  process_payment_function_arn  = module.lambda_functions.process_payment_function_arn
  release_lock_function_arn     = module.lambda_functions.release_lock_function_arn
}

# ---- Phase 6: The API layer ----

module "api_gateway" {
  source       = "./modules/api-gateway"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  tags         = var.tags
  kms_key_arn  = aws_kms_key.app.arn

  cognito_user_pool_arn = module.cognito.user_pool_arn
  state_machine_arn     = module.step_functions.state_machine_arn
}

# ---- Phase 7: The frontend ----

module "frontend" {
  source       = "./modules/frontend"
  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags

  api_invoke_url        = module.api_gateway.invoke_url
  cognito_user_pool_id  = module.cognito.user_pool_id
  cognito_client_id     = module.cognito.user_pool_client_id
  web_acl_id            = aws_wafv2_web_acl.cloudfront.arn
}

# ---- Cross-module wiring that can't live inside either module ----

# WAFv2 for CloudFront: MUST be created with the us-east-1 aliased
# provider (see versions.tf) regardless of var.aws_region -- this is
# a hard CloudFront/WAF requirement.
resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1
  name     = "${var.project_name}-cloudfront-waf-${var.environment}"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWS's own managed Common Rule Set -- covers the standard OWASP
  # Top 10-ish patterns (SQLi, known bad inputs, etc.) without you
  # having to author and maintain rules yourself. A reasonable
  # baseline for a reference architecture; add rate-based rules or
  # a managed bot-control rule set on top for a real production
  # deployment handling meaningful traffic.
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  # Known Bad Inputs includes the Log4Shell (CVE-2021-44228) protection
  # rule -- a separate managed group from the Common Rule Set above,
  # worth having even though Log4j isn't used anywhere in this stack's
  # own code: this WAF sits in front of whatever the frontend's build
  # tooling or a future dependency might pull in, and costs nothing
  # extra to include now.
  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-known-bad-inputs-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-cloudfront-waf-${var.environment}"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# WAF logging: destination log group name MUST start with the literal
# prefix "aws-waf-logs-" -- this is a hard AWS requirement, not a
# naming convention this repo chose.
resource "aws_cloudwatch_log_group" "waf_cloudfront" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.project_name}-cloudfront-${var.environment}"
  retention_in_days = 365
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider                = aws.us_east_1
  resource_arn             = aws_wafv2_web_acl.cloudfront.arn
  log_destination_configs  = [aws_cloudwatch_log_group.waf_cloudfront.arn]
}

# WAFv2 for API Gateway: REGIONAL scope, same region as everything else.
resource "aws_wafv2_web_acl" "api_gateway" {
  name  = "${var.project_name}-apigw-waf-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-apigw-common-rules-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-apigw-known-bad-inputs-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-apigw-waf-${var.environment}"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "waf_api_gateway" {
  name              = "aws-waf-logs-${var.project_name}-apigw-${var.environment}"
  retention_in_days = 365
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "api_gateway" {
  resource_arn             = aws_wafv2_web_acl.api_gateway.arn
  log_destination_configs  = [aws_cloudwatch_log_group.waf_api_gateway.arn]
}

resource "aws_wafv2_web_acl_association" "api_gateway" {
  resource_arn = module.api_gateway.stage_arn
  web_acl_arn  = aws_wafv2_web_acl.api_gateway.arn
}

# This IS Arrow 15's final hop: messages landing in the SQS queue
# (put there by the EventBridge Pipe inside async-notifications)
# now actually get delivered to the Notify Lambda.
resource "aws_lambda_event_source_mapping" "sqs_to_notify" {
  event_source_arn = module.async_notifications.notifications_queue_arn
  function_name    = module.lambda_functions.notify_function_arn
  batch_size       = 10
}

# This IS Arrow 21's final hop: the EventBridge schedule (declared
# inside async-notifications, with no target yet) now actually
# invokes Release Lock on its 5-minute cadence.
resource "aws_cloudwatch_event_target" "timeout_sweep_target" {
  rule      = module.async_notifications.lock_timeout_rule_name
  target_id = "release-lock"
  arn       = module.lambda_functions.release_lock_function_arn
}

resource "aws_lambda_permission" "eventbridge_invoke_release_lock" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_functions.release_lock_function_name
  principal     = "events.amazonaws.com"
  source_arn    = module.async_notifications.lock_timeout_rule_arn
}

# ---- Observability (last, since it references almost everything else) ----

module "observability" {
  source       = "./modules/observability"
  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  release_lock_function_name = module.lambda_functions.release_lock_function_name
  notifications_queue_name   = split(":", module.async_notifications.notifications_queue_arn)[5]
  state_machine_arn           = module.step_functions.state_machine_arn
  alarm_sns_topic_arn         = var.alarm_sns_topic_arn
}
