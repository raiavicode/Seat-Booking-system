"""
Search Lambda -- Arrows 7 (Step Functions -> Search) and 14 (Search -> DynamoDB)

WHY THIS READS DYNAMODB, NOT ELASTICACHE:
This is the actual fix behind the whole project. An earlier version of this
architecture had Search checking Redis for lock status, which meant a lock
written by "Lock Slot" could be invisible to Search if the cache hadn't been
updated yet (or was never updated at all in a failure case) -- so two people
could be shown the same seat as available. DynamoDB is now the only place
status is decided, so Search always sees the true current state, no matter
what Redis thinks.

ElastiCache is still used (see the elasticache module) but only to cache
things that don't affect correctness if stale for a few seconds -- e.g. the
static seat map layout or pricing -- never the live lock status.
"""

import os
import json
import boto3

# Environment variables are wired in by Terraform (see modules/lambda-functions/main.tf)
TABLE_NAME = os.environ["SLOTS_TABLE_NAME"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    """
    Expects event["event_id"] -- e.g. "movie-2026-09-24-19:00".
    Returns every slot for that event and its current status,
    read directly from DynamoDB (the source of truth).
    """
    event_id = event["event_id"]

    # Query, not Scan: partition-key queries only read the one
    # partition they need, which is both cheaper and faster than
    # scanning the whole table as the table grows across many
    # events/shows.
    response = table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("event_id").eq(event_id)
    )

    slots = response.get("Items", [])

    return {
        "statusCode": 200,
        "body": json.dumps({
            "event_id": event_id,
            "slots": slots,
        }),
    }
