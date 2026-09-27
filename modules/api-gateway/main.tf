############################################################
# MODULE: api-gateway
#
# WHAT THIS IS:
#   Arrows 3-6: CloudFront -> API Gateway -> Cognito authorizer
#   check -> Step Functions. This is a REGIONAL REST API (not
#   HTTP API) specifically because native Step Functions service
#   integration (StartExecution/StartSyncExecution without a
#   Lambda in between) is a REST API feature -- HTTP APIs are
#   cheaper but don't support that direct integration as of this
#   writing, and adding a Lambda just to call StartExecution
#   would be one more moving part for zero benefit here.
############################################################

resource "aws_api_gateway_rest_api" "this" {
  name = "${var.project_name}-api-${var.environment}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = merge(var.tags, { ArchitectureArrows = "4" })
}

# ---- Cognito authorizer: Arrow 5 ----
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "${var.project_name}-cognito-authorizer-${var.environment}"
  rest_api_id   = aws_api_gateway_rest_api.this.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [var.cognito_user_pool_arn]
}

resource "aws_api_gateway_resource" "bookings" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "bookings"
}

# Rejects malformed requests (missing required body/params) at the
# API Gateway layer itself, before they ever reach Step Functions --
# cheaper and faster than letting a bad request start a saga execution
# just to fail on its first state.
resource "aws_api_gateway_request_validator" "body_validator" {
  name                        = "${var.project_name}-validate-body-${var.environment}"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = true
}

resource "aws_api_gateway_method" "create_booking" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.bookings.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
  request_validator_id = aws_api_gateway_request_validator.body_validator.id
}

# ---- IAM: lets API Gateway start a Step Functions execution
# directly, no Lambda proxy in between ----

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_step_functions" {
  name               = "${var.project_name}-apigw-sfn-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "apigw_start_execution" {
  statement {
    effect    = "Allow"
    actions   = ["states:StartSyncExecution"]
    resources = [var.state_machine_arn]
  }
}

resource "aws_iam_role_policy" "apigw_start_execution" {
  name   = "${var.project_name}-apigw-start-execution-${var.environment}"
  role   = aws_iam_role.apigw_step_functions.id
  policy = data.aws_iam_policy_document.apigw_start_execution.json
}

# StartSyncExecution (not the async StartExecution) is used here
# because the caller (a browser waiting on a booking attempt)
# needs a synchronous success/fail response with a result payload
# -- not just "yes, an execution was queued." This requires the
# state machine to be an EXPRESS workflow to support sync calls;
# see the note in modules/step-functions if you need the ASL
# switched to STANDARD instead (e.g. for executions that might
# run longer than Express's 5-minute cap).
resource "aws_api_gateway_integration" "create_booking" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.bookings.id
  http_method             = aws_api_gateway_method.create_booking.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${var.aws_region}:states:action/StartSyncExecution"
  credentials             = aws_iam_role.apigw_step_functions.arn

  request_templates = {
    "application/json" = jsonencode({
      input           = "$util.escapeJavaScript($input.json('$'))"
      stateMachineArn = var.state_machine_arn
    })
  }
}

resource "aws_api_gateway_method_response" "create_booking_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.bookings.id
  http_method = aws_api_gateway_method.create_booking.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "create_booking_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.bookings.id
  http_method = aws_api_gateway_method.create_booking.http_method
  status_code = aws_api_gateway_method_response.create_booking_200.status_code

  depends_on = [aws_api_gateway_integration.create_booking]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Forces a new deployment whenever anything about the API's
  # shape changes -- without this trigger, `terraform apply`
  # can update the method/integration resources but leave the
  # DEPLOYED stage still serving the old configuration.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.bookings.id,
      aws_api_gateway_method.create_booking.id,
      aws_api_gateway_integration.create_booking.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment

  # X-Ray tracing on the API Gateway layer itself -- combined
  # with tracing on the Lambdas and Step Functions, this gives
  # you one continuous trace from the edge all the way through
  # the saga (Arrow 13 / 25).
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId    = "$context.requestId"
      ip           = "$context.identity.sourceIp"
      caller       = "$context.identity.caller"
      httpMethod   = "$context.httpMethod"
      resourcePath = "$context.resourcePath"
      status       = "$context.status"
      responseLen  = "$context.responseLength"
    })
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.project_name}-${var.environment}"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Method-level settings (throttling + logging level) applied to every
# method in the stage via the "*/*" wildcard -- separate from
# access_log_settings above, which controls the request LOG FORMAT;
# this controls execution logging verbosity and per-client throttling.
resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    logging_level          = "INFO"
    data_trace_enabled     = false # keep request/response BODIES out of logs -- this API handles payment-adjacent data
    throttling_rate_limit  = 100
    throttling_burst_limit = 50
  }
}
