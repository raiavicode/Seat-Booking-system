"""
Release Lock Lambda -- Arrow 23 (Release Lock -> DynamoDB, reverting status)

This function is invoked from TWO different paths, which is deliberate --
that's the actual reliability pattern this whole project demonstrates:

  1. Arrow 20 (immediate): Step Functions' Catch block on the Process
     Payment state invokes this directly the instant a payment fails.
     No waiting -- the seat is freed up for someone else right away.

  2. Arrow 21 (backup): an EventBridge scheduled rule independently
     checks for locks past their expires_at and calls this same
     function. This exists because the immediate path (1) assumes the
     Step Functions execution itself is still alive to run its Catch
     block -- if the execution crashes, times out at the platform
     level, or Step Functions itself has an outage, path 1 never
     fires. Path 2 is what actually guarantees a seat doesn't stay
     locked forever, independent of whether path 1 worked.

Neither path alone is sufficient on its own for a system that has to be
correct even when nobody's watching -- exactly the property autonomous
(agent-driven) booking traffic will demand, since there's no human left
to notice a seat stuck in limbo and go complain about it.
"""

import os
import time
import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ["SLOTS_TABLE_NAME"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    # EventBridge's scheduled rule (Arrow 21) invokes this function with
    # no event_id/slot_id -- that shape is what tells us "this is the
    # timeout sweep," not a targeted release for one specific booking.
    if "event_id" not in event:
        return _sweep_expired_locks()

    return _release_one(event["event_id"], event["slot_id"], event.get("booking_id"))


def _sweep_expired_locks():
    """
    The Arrow-21 safety net: find every lock that's past its expires_at
    and release it, independent of whether the Arrow-20 immediate
    compensation path ever ran. Queries the status-expires-index GSI
    (see modules/dynamodb/main.tf) rather than scanning the whole table
    -- PENDING locks are a small slice of all bookings at any moment.
    """
    now = int(time.time())
    released = 0

    response = table.query(
        IndexName="status-expires-index",
        KeyConditionExpression=Key("status").eq("PENDING") & Key("expires_at").lt(now),
    )

    for item in response.get("Items", []):
        result = _release_one(item["event_id"], item["slot_id"], item.get("booking_id"))
        if result.get("released"):
            released += 1

    return {"swept": len(response.get("Items", [])), "released": released}


def _release_one(event_id, slot_id, booking_id):

    update_kwargs = {
        "Key": {"event_id": event_id, "slot_id": slot_id},
        "UpdateExpression": "SET #status = :available REMOVE booking_id, locked_at, expires_at",
        "ExpressionAttributeNames": {"#status": "status"},
        "ExpressionAttributeValues": {":available": "AVAILABLE"},
    }

    # If we know which booking_id we're releasing (the immediate,
    # Arrow-20 path always knows this), guard the release with a
    # condition so we never accidentally release a DIFFERENT booking
    # that grabbed the seat in between -- e.g. if this function gets
    # invoked twice (once from each path) for the same original lock,
    # the second call should be a safe no-op, not a data-corrupting
    # overwrite of whoever holds the seat now.
    if booking_id:
        update_kwargs["ConditionExpression"] = "booking_id = :booking_id"
        update_kwargs["ExpressionAttributeValues"][":booking_id"] = booking_id

    try:
        table.update_item(**update_kwargs)
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        # The seat was already released (or re-locked by someone else)
        # -- this is expected and safe when both the immediate and
        # timeout-backup paths fire for the same original lock.
        return {"released": False, "reason": "ALREADY_RELEASED_OR_RELOCKED"}

    return {"released": True, "event_id": event_id, "slot_id": slot_id}
