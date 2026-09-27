############################################################
# MODULE: observability
#
# WHAT THIS IS:
#   X-Ray tracing itself is enabled per-resource elsewhere (each
#   Lambda's tracing_config, the API Gateway stage, the state
#   machine) -- this module is specifically the CloudWatch layer:
#   a dashboard for humans, and alarms for the failure modes that
#   actually matter to THIS architecture's reliability story, not
#   generic "CPU high" noise.
############################################################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Release Lock invocations (should track BOTH payment failures AND the timeout sweep)"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.release_lock_function_name],
            [".", "Errors", ".", "."],
          ]
          stat = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Notify queue depth (a growing number here means notifications are falling behind)"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.notifications_queue_name],
          ]
          stat = "Average"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Booking saga: failed executions"
          region = var.aws_region
          metrics = [
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn],
          ]
          stat = "Sum"
        }
      },
    ]
  })
}

# ---- The alarm that actually matters most for THIS architecture ----
# If Release Lock's error rate spikes, locks stop being released --
# which means seats silently stop coming back onto the market. This
# is the single metric most directly tied to the reliability story
# this whole project is built around.
resource "aws_cloudwatch_metric_alarm" "release_lock_errors" {
  alarm_name          = "${var.project_name}-release-lock-errors-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Release Lock is failing -- expired/failed bookings will stop freeing up seats. Investigate immediately; this directly breaks the reliability guarantee this architecture is built around."

  dimensions = {
    FunctionName = var.release_lock_function_name
  }

  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]
}

# A growing, never-draining notifications queue means the Arrow-15
# pipeline (DynamoDB Streams -> SQS -> Notify) is backed up -- users
# have paid but aren't getting confirmations.
resource "aws_cloudwatch_metric_alarm" "notify_queue_backlog" {
  alarm_name          = "${var.project_name}-notify-backlog-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "Notification queue is backing up -- confirmed bookings aren't reaching users in a timely way."

  dimensions = {
    QueueName = var.notifications_queue_name
  }

  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]
}
