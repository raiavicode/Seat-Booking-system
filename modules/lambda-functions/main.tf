############################################################
# MODULE: lambda-functions
#
# WHAT THIS IS:
#   Declares all 5 Lambda functions in the architecture and
#   attaches each one's SPECIFIC permissions to the shared
#   execution role from the iam module. Each function is kept
#   as an explicit, separate resource block (rather than a
#   for_each loop over a map) on purpose -- this is a reference
#   repo meant to be read and tweaked function-by-function, and
#   an abstracted loop makes it harder to find "the Lock Slot
#   function" and see exactly what it's granted.
#
# PACKAGING NOTE:
#   Each function's code lives in ../../lambda-src/<name>/ as
#   plain Python files. archive_file zips that directory at
#   `terraform apply` time -- there's no separate build step for
#   these simple stubs. If you add real dependencies (e.g.
#   requests, stripe's SDK), you'll need to vendor them into the
#   lambda-src/<name>/ folder first (pip install -t) or switch to
#   a Lambda Layer -- archive_file alone won't install packages
#   for you.
############################################################

# Shared dead-letter queue: if any of these functions fails ALL of its
# retries on an ASYNC invocation (this matters specifically for the
# SQS-triggered Notify function and the EventBridge-triggered sweep on
# Release Lock -- Search/Lock Slot/Process Payment are invoked
# synchronously from Step Functions/API Gateway and don't use DLQs the
# same way), the failed event lands here instead of being silently
# dropped. One shared DLQ across all 5 functions is a reasonable
# simplification for a reference repo; split into per-function DLQs if
# you need to distinguish which function failed without checking each
# message's source metadata.
resource "aws_sqs_queue" "lambda_dlq" {
  name               = "${var.project_name}-lambda-dlq-${var.environment}"
  kms_master_key_id  = var.kms_key_arn
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_dlq_send" {
  statement {
    sid       = "SendToDLQ"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq.arn]
  }
}

resource "aws_iam_policy" "lambda_dlq_send" {
  name   = "${var.project_name}-lambda-dlq-send-${var.environment}"
  policy = data.aws_iam_policy_document.lambda_dlq_send.json
}

resource "aws_iam_role_policy_attachment" "lambda_dlq_send" {
  role       = var.lambda_execution_role_name
  policy_arn = aws_iam_policy.lambda_dlq_send.arn
}

# ---- Search ----

data "archive_file" "search" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda-src/search"
  output_path = "${path.module}/../../.build/search.zip"
}

resource "aws_lambda_function" "search" {
  function_name = "${var.project_name}-search-${var.environment}"
  role          = var.lambda_execution_role_arn
  handler       = "handler.handler"     # file.function -- matches handler.py's `def handler(...)`
  runtime       = "python3.12"
  timeout       = 10                     # seconds; a search/query should never legitimately take longer
  memory_size   = 256

  filename         = data.archive_file.search.output_path
  source_code_hash = data.archive_file.search.output_base64sha256

  environment {
    variables = {
      SLOTS_TABLE_NAME = var.slots_table_name
    }
  }

  tracing_config {
    mode = "Active" # enables X-Ray tracing -- Arrow 13/25
  }

  # Customer-managed key encrypts the env vars above at rest (rather
  # than AWS's default key) -- the execution role's Decrypt permission
  # for this is granted in the iam module.
  kms_key_arn = var.kms_key_arn

  # Caps how many concurrent executions this one function can consume
  # from the account's shared Lambda concurrency pool -- without a
  # limit, a traffic spike hitting Search could starve every OTHER
  # function (including Release Lock, which is the one function you
  # really don't want throttled) of the concurrency it needs to run.
  reserved_concurrent_executions = 20

  tags = merge(var.tags, { ArchitectureArrows = "7,14" })
}

resource "aws_iam_role_policy_attachment" "search_dynamodb" {
  role       = var.lambda_execution_role_name
  policy_arn = var.slots_read_write_policy_arn
}

# ---- Lock Slot ----

data "archive_file" "lock_slot" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda-src/lock-slot"
  output_path = "${path.module}/../../.build/lock-slot.zip"
}

resource "aws_lambda_function" "lock_slot" {
  function_name = "${var.project_name}-lock-slot-${var.environment}"
  role          = var.lambda_execution_role_arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.lock_slot.output_path
  source_code_hash = data.archive_file.lock_slot.output_base64sha256

  environment {
    variables = {
      SLOTS_TABLE_NAME = var.slots_table_name
      LOCK_TTL_SECONDS = tostring(var.lock_ttl_seconds)
    }
  }

  tracing_config {
    mode = "Active"
  }

  kms_key_arn = var.kms_key_arn

  # Deliberately a SMALLER limit than Search -- Lock Slot's job is to
  # win or lose a race quickly, not to be infinitely scalable; this
  # also acts as a natural throttle protecting DynamoDB from an
  # extreme thundering-herd scenario (e.g. a bot script hammering one
  # popular seat).
  reserved_concurrent_executions = 20

  tags = merge(var.tags, {
    ArchitectureArrows = "9,11"
    Note               = "This function's ConditionExpression is the arrow-11 reliability fix -- see handler.py"
  })
}

resource "aws_iam_role_policy_attachment" "lock_slot_dynamodb" {
  role       = var.lambda_execution_role_name
  policy_arn = var.slots_read_write_policy_arn
}

# ---- Process Payment ----

data "archive_file" "process_payment" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda-src/process-payment"
  output_path = "${path.module}/../../.build/process-payment.zip"
}

resource "aws_lambda_function" "process_payment" {
  function_name = "${var.project_name}-process-payment-${var.environment}"
  role          = var.lambda_execution_role_arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  # Payment gateways can be slow -- longer timeout than the other
  # functions, but still bounded so a hung gateway call can't stall
  # a Step Functions execution indefinitely (the state machine has
  # its own timeout too -- see modules/step-functions).
  timeout       = 25
  memory_size   = 256

  filename         = data.archive_file.process_payment.output_path
  source_code_hash = data.archive_file.process_payment.output_base64sha256

  environment {
    variables = {
      PAYMENT_GATEWAY_SECRET_ARN = var.payment_gateway_secret_arn
      CACHE_ENDPOINT             = var.cache_endpoint
    }
  }

  tracing_config {
    mode = "Active"
  }

  # This function needs to reach ElastiCache, which lives inside a
  # VPC -- so this Lambda (uniquely among the five) must also run
  # inside that VPC. The others don't need VPC access and are kept
  # OUT of the VPC deliberately: VPC-attached Lambdas have slower
  # cold starts and can't reach the public internet without a NAT
  # Gateway (an extra cost), so only pay that price where it's
  # actually needed.
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  kms_key_arn = var.kms_key_arn

  # Lower than the others on purpose -- payment gateway calls are the
  # most expensive (in both latency and $) part of this system to run
  # at high concurrency, and most gateways have their own rate limits
  # you'd hit before AWS's anyway.
  reserved_concurrent_executions = 10

  tags = merge(var.tags, { ArchitectureArrows = "10,12,22" })
}

resource "aws_iam_role_policy_attachment" "process_payment_secret" {
  role       = var.lambda_execution_role_name
  policy_arn = var.payment_secret_read_policy_arn
}

resource "aws_iam_role_policy_attachment" "process_payment_vpc" {
  # Required for ANY Lambda placed inside a VPC (vpc_config above) --
  # without this, the function can create an ENI but can't clean it
  # up, and can fail to reach even its own logs.
  role       = var.lambda_execution_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ---- Release Lock ----

data "archive_file" "release_lock" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda-src/release-lock"
  output_path = "${path.module}/../../.build/release-lock.zip"
}

resource "aws_lambda_function" "release_lock" {
  function_name = "${var.project_name}-release-lock-${var.environment}"
  role          = var.lambda_execution_role_arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.release_lock.output_path
  source_code_hash = data.archive_file.release_lock.output_base64sha256

  environment {
    variables = {
      SLOTS_TABLE_NAME = var.slots_table_name
    }
  }

  tracing_config {
    mode = "Active"
  }

  kms_key_arn = var.kms_key_arn

  # Deliberately the HIGHEST limit of the five: this function is the
  # one thing standing between a failure and a seat staying locked
  # forever (see the module header comment). It should be the last
  # function in this system to ever be starved of concurrency.
  reserved_concurrent_executions = 30

  # If Release Lock itself fails on an async invocation (the
  # EventBridge sweep path -- Step Functions' synchronous Catch-path
  # invocation doesn't use this), the failed event goes here instead
  # of vanishing. Given how central this function is to the
  # reliability story, treat anything landing in this DLQ as a
  # page-worthy incident, not routine noise.
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  tags = merge(var.tags, {
    ArchitectureArrows = "20,21,23"
    Note               = "Invoked from Step Functions' Catch (arrow 20, immediate) AND from EventBridge (arrow 21, timeout backup)"
  })
}

resource "aws_iam_role_policy_attachment" "release_lock_dynamodb" {
  role       = var.lambda_execution_role_name
  policy_arn = var.slots_read_write_policy_arn
}

# ---- Notify ----

data "archive_file" "notify" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda-src/notify"
  output_path = "${path.module}/../../.build/notify.zip"
}

resource "aws_lambda_function" "notify" {
  function_name = "${var.project_name}-notify-${var.environment}"
  role          = var.lambda_execution_role_arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 15
  memory_size   = 256

  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256

  environment {
    variables = {
      SES_SENDER_ADDRESS = var.ses_sender_address
      SNS_TOPIC_ARN       = var.sns_topic_arn
    }
  }

  tracing_config {
    mode = "Active"
  }

  kms_key_arn = var.kms_key_arn

  reserved_concurrent_executions = 20

  # This function is SQS-triggered (async, from its own perspective)
  # -- if it exhausts its retries on a batch, the batch's messages go
  # here rather than being lost, so a bug in email/SNS formatting
  # doesn't silently swallow confirmation notifications.
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  tags = merge(var.tags, { ArchitectureArrows = "15,16,17,18,19" })
}

resource "aws_iam_role_policy_attachment" "notify_ses_sns" {
  role       = var.lambda_execution_role_name
  policy_arn = var.notify_permissions_policy_arn
}

resource "aws_iam_role_policy_attachment" "notify_sqs_consume" {
  role       = var.lambda_execution_role_name
  policy_arn = var.sqs_consume_policy_arn
}

# The SQS -> Notify wiring (the literal Arrow-15 fix: DynamoDB Streams ->
# SQS -> this Lambda, replacing a direct Process Payment -> SQS call) is
# declared in modules/async-notifications, not here -- it needs the SQS
# queue ARN, which that module owns. See event_source_mapping there.
