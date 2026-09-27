############################################################
# MODULE: step-functions
#
# WHAT THIS IS:
#   The saga orchestrator. Arrows 6-9-12 (API Gateway -> Step
#   Functions -> Lock Slot -> Process Payment) are the "happy
#   path" states below. Arrow 20 (Process Payment -> Release
#   Lock on failure) is the Catch block on the ProcessPayment
#   state -- this is the ACTUAL mechanism behind that arrow, not
#   a separate piece of code. Step Functions itself is what
#   notices the failure and routes to compensation; no Lambda
#   calls another Lambda directly.
#
# WHY A SAGA PATTERN (vs. a single Lambda doing everything in
# a try/except):
#   Once you've made an external, hard-to-undo call (charging a
#   real credit card), you can't just "roll back a transaction"
#   the way a database would -- there's no ACID rollback across
#   DynamoDB + a third-party payment gateway. A saga instead
#   defines an explicit COMPENSATING action (release the lock)
#   for each step that can't be undone any other way, and an
#   orchestrator (Step Functions) that's responsible for running
#   that compensation reliably if a later step fails. That's
#   what the ASL definition below actually encodes.
############################################################

resource "aws_sfn_state_machine" "booking_saga" {
  name     = "${var.project_name}-booking-saga-${var.environment}"
  role_arn = aws_iam_role.step_functions.arn

  definition = jsonencode({
    Comment = "Seat booking saga: lock -> pay -> (compensate on failure)"
    StartAt = "LockSlot"

    States = {

      # Arrow 9: Step Functions invokes Lock Slot.
      LockSlot = {
        Type     = "Task"
        Resource = var.lock_slot_function_arn
        # If Lock Slot itself throws (e.g. a transient DynamoDB
        # throttle, NOT the expected "already locked" business
        # response -- that comes back as a normal successful
        # payload with locked:false, not an exception), retry a
        # couple of times before giving up. Exponential backoff
        # avoids hammering DynamoDB harder during a transient
        # capacity blip.
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 1
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Next = "CheckLockResult"
      }

      # Business-logic branch: did we actually get the lock?
      # (Distinct from an infrastructure error, which Retry above
      # already handled -- this checks the LOGICAL result.)
      CheckLockResult = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.locked"
          BooleanEquals = false
          Next          = "SeatUnavailable"
        }]
        Default = "ProcessPayment"
      }

      SeatUnavailable = {
        Type  = "Fail"
        Error = "SEAT_ALREADY_LOCKED"
        Cause = "Another request already holds a valid lock on this seat."
      }

      # Arrow 12: Step Functions invokes Process Payment.
      # Arrow 20 lives entirely in the Catch block below.
      ProcessPayment = {
        Type     = "Task"
        Resource = var.process_payment_function_arn

        # THIS is Arrow 20. If ProcessPayment's Lambda raises
        # ANY error (see the "raise Exception" in its handler.py
        # for why that matters), Step Functions catches it here
        # and routes to ReleaseLock -- immediately, without
        # waiting for the Arrow-21 timeout sweep to eventually
        # notice. ResultPath "$.error" preserves the original
        # input (event_id/slot_id/booking_id) alongside the
        # error details, so ReleaseLock still has what it needs
        # to know WHICH lock to release.
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "ReleaseLockOnFailure"
        }]

        Next = "BookingConfirmed"
      }

      ReleaseLockOnFailure = {
        Type     = "Task"
        Resource = var.release_lock_function_arn
        Next     = "PaymentFailed"
      }

      PaymentFailed = {
        Type  = "Fail"
        Error = "PAYMENT_FAILED"
        Cause = "Payment was declined; the lock has been released."
      }

      BookingConfirmed = {
        Type = "Succeed"
      }
    }
  })

  # Logs every state transition to CloudWatch -- combined with
  # X-Ray tracing on the underlying Lambdas, this is what powers
  # the "Observability & Secrets" zone of the diagram (Arrow 13).
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = merge(var.tags, { ArchitectureArrows = "6,7,9,12,20" })
}

resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${var.project_name}-booking-saga-${var.environment}"
  # 1 year: long enough to investigate a dispute or incident that
  # surfaces well after the fact (e.g. a chargeback), which is a real
  # consideration for anything touching payment flows -- 30 days is
  # fine for debugging, not for that kind of retrospective audit.
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ---- IAM: Step Functions needs permission to invoke each Lambda ----

data "aws_iam_policy_document" "step_functions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions" {
  name               = "${var.project_name}-sfn-execution-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "step_functions_invoke_lambdas" {
  statement {
    sid       = "InvokeBookingLambdas"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    # Scoped to exactly the 3 functions this state machine calls --
    # notably NOT Search or Notify, which this saga never invokes
    # directly. Least privilege: a compromised or buggy state
    # machine definition can't be used to invoke arbitrary Lambdas
    # in the account.
    resources = [
      var.lock_slot_function_arn,
      var.process_payment_function_arn,
      var.release_lock_function_arn,
    ]
  }

  statement {
    sid    = "WriteExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"] # CloudWatch Logs' own API requires this for the log-delivery actions specifically -- there is no resource-level ARN to scope these particular actions to.
  }
}

resource "aws_iam_role_policy" "step_functions_permissions" {
  name   = "${var.project_name}-sfn-permissions-${var.environment}"
  role   = aws_iam_role.step_functions.id
  policy = data.aws_iam_policy_document.step_functions_invoke_lambdas.json
}
