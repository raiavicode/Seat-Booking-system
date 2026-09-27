"""
Notify Lambda -- Arrows 16-19 (SQS -> Notify -> SES/SNS/Push)

WHY THIS IS TRIGGERED BY SQS (FED BY DYNAMODB STREAMS), NOT CALLED
DIRECTLY BY PROCESS PAYMENT:
An earlier version of this architecture had Process Payment call SQS
directly right after charging the card. The bug: that notify message could
be enqueued and processed BEFORE the DynamoDB write actually committed (or
even if the write later failed for an unrelated reason) -- so a user could
get a "you're confirmed!" notification for a booking that doesn't actually
exist in the system of record. Routing through DynamoDB Streams (Arrow 15)
means this function only ever fires from a write that DynamoDB has already
durably committed -- notification can never get ahead of reality.
"""

import os
import json
import boto3

SES_SENDER = os.environ["SES_SENDER_ADDRESS"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

ses = boto3.client("ses")
sns = boto3.client("sns")


def handler(event, context):
    """
    event["Records"] here are SQS records, each wrapping one DynamoDB
    Streams record (old + new image) that the async-notifications module
    wired SQS to receive. See modules/async-notifications/main.tf for the
    Streams -> SQS event source mapping.
    """
    for record in event["Records"]:
        body = json.loads(record["body"])
        _handle_stream_record(body)

    return {"processed": len(event["Records"])}


def _handle_stream_record(stream_record):
    new_image = stream_record.get("dynamodb", {}).get("NewImage", {})
    old_image = stream_record.get("dynamodb", {}).get("OldImage", {})

    new_status = new_image.get("status", {}).get("S")
    old_status = old_image.get("status", {}).get("S")

    # Only notify on an actual status TRANSITION, not on every write to
    # the item (e.g. don't fire again if some unrelated attribute changes).
    if new_status == old_status:
        return

    if new_status == "CONFIRMED":
        _send_confirmation(new_image)
    elif new_status == "AVAILABLE" and old_status == "PENDING":
        # A lock was released (either the Arrow-20 immediate compensation
        # or the Arrow-21 timeout backup) -- this is intentionally silent
        # by default. Uncomment if you want to notify the ORIGINAL holder
        # that their lock expired.
        pass


def _send_confirmation(item):
    email = item.get("customer_email", {}).get("S")
    if not email:
        return

    ses.send_email(
        Source=SES_SENDER,
        Destination={"ToAddresses": [email]},
        Message={
            "Subject": {"Data": "Your booking is confirmed"},
            "Body": {"Text": {"Data": "Your seat is confirmed. See you soon!"}},
        },
    )

    # Also fan out to SNS for any other subscribers (push notification
    # service, ops Slack channel, etc.) -- see the async-notifications
    # module for what's subscribed to this topic.
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({"event": "booking_confirmed", "item": item}),
    )
