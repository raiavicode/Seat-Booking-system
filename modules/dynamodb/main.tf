############################################################
# MODULE: dynamodb
#
# WHAT THIS IS IN THE ARCHITECTURE:
#   This is the single source of truth for seat/slot status.
#   Arrow 11 (λ Lock Slot -> DynamoDB) writes a PENDING status
#   here. Arrow 14 (Search -> DynamoDB) reads from here, not
#   from Redis/ElastiCache. That's the actual reliability fix
#   this whole project is built around: before this design,
#   Search checked ElastiCache for locks, but Lock Slot could
#   write a lock that Search never saw, so two people could be
#   shown the same "available" seat at once. Making DynamoDB
#   authoritative for status closes that gap.
#
# WHY DYNAMODB SPECIFICALLY (vs. staying on Redis, vs. RDS):
#   - Conditional writes (ConditionExpression) give us atomic
#     "only lock this seat if nobody else has" semantics without
#     needing a separate distributed lock service.
#   - DynamoDB Streams give us a durable, ordered changelog of
#     every status change, which is what Arrow 15 needs (Streams
#     -> SQS) to notify people only AFTER a write actually landed
#     — replacing a racier direct Lambda -> SQS call that could
#     fire before the write was confirmed.
#   - Serverless / on-demand billing matches a bursty booking
#     workload (ticket on-sales, flash-sale spikes) better than
#     a fixed-capacity RDS instance would, without you having to
#     manage failover yourself.
############################################################

# ----------------------------------------------------------
# The core table: one row per bookable slot/seat.
# ----------------------------------------------------------
resource "aws_dynamodb_table" "slots" {
  name = "${var.project_name}-slots-${var.environment}"

  # PAY_PER_REQUEST = on-demand billing. No capacity planning,
  # scales automatically with traffic. Swap to PROVISIONED with
  # read/write capacity units if you have predictable, steady
  # traffic and want cheaper steady-state pricing -- on-demand
  # costs more per-request but removes the risk of throttling
  # during a sudden on-sale spike, which is the scenario this
  # architecture is actually designed to survive.
  billing_mode = "PAY_PER_REQUEST"

  # Partition key: which "event" or "show" the slot belongs to.
  # Sort key: the specific slot/seat id within that event.
  # This combination lets you query "all slots for event X"
  # cheaply (a single partition query) while still addressing
  # one exact seat by its sort key for the lock/release calls.
  hash_key  = "event_id"
  range_key = "slot_id"

  attribute {
    name = "event_id"
    type = "S" # string, e.g. "movie-2026-09-24-7pm"
  }

  attribute {
    name = "slot_id"
    type = "S" # string, e.g. "seat-C12"
  }

  # These two attributes exist ONLY so the GSI below can be built on
  # them -- they're already present as plain (non-key) attributes on
  # every item written by Lock Slot; declaring them here just tells
  # DynamoDB "these are indexable," it doesn't create the data itself.
  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "expires_at"
    type = "N"
  }

  # This GSI is what makes the Arrow-21 timeout sweep possible without
  # a full table Scan. The EventBridge-triggered sweep in Release Lock
  # queries this index for status = "PENDING", then filters client-side
  # for expires_at < now -- a targeted Query against a handful of
  # currently-pending locks, not a scan of every booking ever made.
  global_secondary_index {
    name            = "status-expires-index"
    hash_key        = "status"
    range_key       = "expires_at"
    projection_type = "ALL"
  }

  # ----------------------------------------------------------
  # DynamoDB Streams: this is what powers Arrow 15.
  # NEW_AND_OLD_IMAGES means every stream record includes both
  # the item's state before AND after the change, which the
  # notifier Lambda needs to tell "became LOCKED" apart from
  # "became AVAILABLE" (a release) -- both are just "the status
  # attribute changed" without the old image to compare against.
  # ----------------------------------------------------------
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # Point-in-time recovery: lets you restore the table to any
  # point in the last 35 days. Cheap insurance against a bad
  # deploy or bug that corrupts booking data; costs a small
  # percentage on top of storage, generally worth it for
  # anything holding real transactional state.
  point_in_time_recovery {
    enabled = true
  }

  # Server-side encryption using a customer-managed KMS key rather than
  # AWS's default owned key -- gives you an actual audit trail
  # (CloudTrail records every Decrypt call) on a table holding booking
  # and payment-adjacent data.
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = merge(var.tags, {
    Name      = "${var.project_name}-slots-${var.environment}"
    Component = "data-layer"
    # This tag is just for readers tracing the architecture
    # diagram back to this file -- not functionally required.
    ArchitectureArrows = "11,14,15,23"
  })
}

# ----------------------------------------------------------
# IAM policy document (not yet attached to a role -- that
# happens in the lambda-functions module, which references
# this policy's ARN). Kept here, next to the table it grants
# access to, so the permissions are easy to audit against the
# actual table schema above.
# ----------------------------------------------------------
data "aws_iam_policy_document" "slots_rw" {
  statement {
    sid    = "SlotsTableReadWrite"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      # ConditionCheckItem is what lets Lock Slot's conditional
      # write fail cleanly (instead of silently overwriting)
      # when another request already holds the lock -- this is
      # the actual mechanism behind the Arrow 11 fix, not just
      # "writing to DynamoDB" in general.
      "dynamodb:ConditionCheckItem",
    ]

    resources = [
      aws_dynamodb_table.slots.arn,
      # The GSI needs its own resource line -- DynamoDB treats index
      # access as a distinct permission from base-table access, even
      # though it's "the same table" conceptually.
      "${aws_dynamodb_table.slots.arn}/index/*",
    ]
  }
}

resource "aws_iam_policy" "slots_rw" {
  name        = "${var.project_name}-slots-rw-${var.environment}"
  description = "Read/write access to the slots table for booking Lambdas"
  policy      = data.aws_iam_policy_document.slots_rw.json
}
