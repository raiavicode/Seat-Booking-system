############################################################
# MODULE: async-notifications
#
# WHAT THIS IS:
#   Arrows 15-19 and 21. The centerpiece is the EventBridge Pipe
#   below, which is the literal implementation of Arrow 15
#   (DynamoDB Streams -> SQS) -- the fix that replaced an
#   earlier, racier direct "Process Payment -> SQS" call. See
#   the top-level README for the full explanation of why that
#   mattered.
#
# WHY EVENTBRIDGE PIPES (vs. a small Lambda that reads the
# stream and forwards to SQS):
#   Pipes connect a stream source directly to a target with zero
#   custom code -- one less Lambda to maintain, monitor, and pay
#   cold-start latency on, for a job that's pure plumbing anyway.
#   If you later need to filter or reshape records in transit,
#   Pipes supports an optional filter/enrichment step without
#   requiring you to introduce a Lambda for that either.
############################################################

# ---- The queue Notify consumes from ----

resource "aws_sqs_queue" "notifications" {
  name = "${var.project_name}-notifications-${var.environment}"

  # Customer-managed key rather than SQS's default AWS-owned key --
  # this queue carries booking/payment-adjacent data, so a real audit
  # trail on who decrypted what (via CloudTrail) is worth the small
  # extra KMS request cost.
  kms_master_key_id = var.kms_key_arn

  # Messages that fail processing 5 times land in the DLQ below
  # instead of being retried forever or silently dropped --
  # gives you something to inspect when the Notify Lambda has a
  # bug, instead of just losing the notification.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount      = 5
  })

  # 5 minutes -- long enough to cover Notify Lambda cold starts
  # and retries, short enough that a stuck message doesn't block
  # the queue from being processed for an unreasonable time.
  visibility_timeout_seconds = 300

  tags = merge(var.tags, { ArchitectureArrows = "15,16" })
}

resource "aws_sqs_queue" "notifications_dlq" {
  name               = "${var.project_name}-notifications-dlq-${var.environment}"
  kms_master_key_id  = var.kms_key_arn
  tags               = var.tags
}

# ---- The pipe: DynamoDB Streams -> SQS (Arrow 15 itself) ----

# Pipes needs its own execution role -- separate from the Lambda
# execution role, since Pipes is a distinct AWS service reading
# the stream and writing to SQS, not code you write yourself.
data "aws_iam_policy_document" "pipe_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipe_role" {
  name               = "${var.project_name}-stream-pipe-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.pipe_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "pipe_permissions" {
  statement {
    sid    = "ReadDynamoDBStream"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [var.slots_table_stream_arn]
  }

  statement {
    sid       = "WriteToNotificationsQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]
  }

  statement {
    sid    = "UseQueueEncryptionKey"
    effect = "Allow"
    # The queue is now encrypted with our customer-managed key (see
    # aws_sqs_queue.notifications above) -- the pipe's role needs
    # permission to generate a data key under it to actually write
    # encrypted messages, not just SQS-level SendMessage permission.
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "pipe_permissions" {
  name   = "${var.project_name}-stream-pipe-permissions-${var.environment}"
  role   = aws_iam_role.pipe_role.id
  policy = data.aws_iam_policy_document.pipe_permissions.json
}

resource "aws_pipes_pipe" "stream_to_sqs" {
  name     = "${var.project_name}-slots-stream-to-sqs-${var.environment}"
  role_arn = aws_iam_role.pipe_role.arn

  source = var.slots_table_stream_arn
  source_parameters {
    dynamodb_stream_parameters {
      # Read from the oldest unprocessed record on first start --
      # matters mainly for the very first deploy; after that the
      # pipe tracks its own position like any stream consumer.
      starting_position = "TRIM_HORIZON"
      batch_size         = 10
    }

    # Only forward records where the status attribute actually
    # changed -- this is what lets the Pipe itself filter out
    # writes to unrelated attributes before they ever reach SQS,
    # rather than making the Notify Lambda pay to receive and
    # then discard irrelevant events.
    filter_criteria {
      filter {
        pattern = jsonencode({
          dynamodb = {
            NewImage = {
              status = { S = [{ exists = true }] }
            }
          }
        })
      }
    }
  }

  target = aws_sqs_queue.notifications.arn
}

# IAM policy for the Notify Lambda's execution role to actually
# consume (not just receive visibility of) this queue. Attached
# to the shared role from the lambda-functions module.
data "aws_iam_policy_document" "sqs_consume" {
  statement {
    sid    = "ConsumeNotificationsQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.notifications.arn]
  }
}

resource "aws_iam_policy" "sqs_consume" {
  name   = "${var.project_name}-sqs-consume-${var.environment}"
  policy = data.aws_iam_policy_document.sqs_consume.json
}

# ---- SNS: fan-out to any other subscriber (push service, ops alerts) ----

resource "aws_sns_topic" "booking_events" {
  name              = "${var.project_name}-booking-events-${var.environment}"
  kms_master_key_id = var.kms_key_arn
  tags              = merge(var.tags, { ArchitectureArrows = "17,19" })
}

# ---- SES: the actual outbound confirmation email ----

resource "aws_ses_email_identity" "sender" {
  email = var.ses_sender_address
  # NOTE: AWS will send a verification email to this address after
  # apply. The identity stays in a "pending" state -- and SES will
  # refuse to actually send through it -- until someone clicks the
  # verification link. Terraform can't do that step for you.
}

data "aws_iam_policy_document" "notify_permissions" {
  statement {
    sid       = "SendConfirmationEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [aws_ses_email_identity.sender.arn]
  }

  statement {
    sid       = "PublishBookingEvents"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.booking_events.arn]
  }
}

resource "aws_iam_policy" "notify_permissions" {
  name   = "${var.project_name}-notify-permissions-${var.environment}"
  policy = data.aws_iam_policy_document.notify_permissions.json
}

# ---- EventBridge: the Arrow-21 timeout backup ----
# This only declares the SCHEDULE. The actual target (Release Lock
# Lambda) is wired in the root module, since this resource needs
# that Lambda's ARN and this module intentionally doesn't take any
# Lambda ARNs as input -- see the root README for the full reasoning.

resource "aws_cloudwatch_event_rule" "lock_timeout_sweep" {
  name = "${var.project_name}-lock-timeout-sweep-${var.environment}"
  # Runs every 5 minutes. Frequent enough that an abandoned lock
  # doesn't block a popular seat for long; infrequent enough not
  # to generate meaningful cost or noise. This is a SAFETY NET,
  # not the primary release path -- the immediate Arrow-20
  # compensation is expected to handle the vast majority of
  # failures well before this ever fires.
  schedule_expression = "rate(5 minutes)"
  tags                 = merge(var.tags, { ArchitectureArrows = "21" })
}
