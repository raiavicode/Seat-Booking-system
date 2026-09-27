"""
Process Payment Lambda -- Arrow 12 (Step Functions -> Process Payment),
Arrow 10 (Process Payment -> ElastiCache), Arrow 22 (reads Secrets Manager)

NOTE ON SCOPE: the actual call to your payment gateway (Stripe, Adyen,
whatever you use) is stubbed out below -- every gateway's API is different,
so this is intentionally the one part of this reference implementation
you're expected to replace with real integration code. Everything AROUND
that call (secret retrieval, error handling, what Step Functions does on
failure) is real and meant to be used as-is.

On failure, this function raises an exception rather than swallowing the
error -- that's deliberate. Step Functions' Catch block (see the
step-functions module) is what turns "this Lambda raised an error" into
"invoke Release Lock" (Arrow 20). If you catch and swallow the error here
instead, Step Functions never sees the failure and the compensation path
never fires -- the seat would stay locked with no payment taken.
"""

import os
import json
import boto3

SECRET_ARN = os.environ["PAYMENT_GATEWAY_SECRET_ARN"]
CACHE_ENDPOINT = os.environ["CACHE_ENDPOINT"]

secrets_client = boto3.client("secretsmanager")

# Lazily fetch and cache the secret in the execution environment (not in
# the cache cluster -- this is just a Python-process-level cache) so a
# warm Lambda invocation doesn't call Secrets Manager on every request.
_secret_cache = {}


def _get_gateway_credentials():
    if "value" not in _secret_cache:
        response = secrets_client.get_secret_value(SecretId=SECRET_ARN)
        _secret_cache["value"] = json.loads(response["SecretString"])
    return _secret_cache["value"]


def handler(event, context):
    event_id = event["event_id"]
    slot_id = event["slot_id"]
    booking_id = event["booking_id"]
    amount_cents = event["amount_cents"]

    credentials = _get_gateway_credentials()

    # ---- REPLACE THIS BLOCK with your real payment gateway call ----
    payment_succeeded = _call_payment_gateway_stub(credentials, amount_cents)
    # ------------------------------------------------------------------

    if not payment_succeeded:
        # Raising here is what lets Step Functions' Catch block trigger
        # the Arrow-20 compensation (Release Lock) immediately. See the
        # comment in the module docstring above before changing this.
        raise Exception("PAYMENT_DECLINED")

    # On success, cache the confirmed booking so a repeat "is this booked"
    # check (e.g. from a confirmation page reload) doesn't have to hit
    # DynamoDB every time. Short TTL: this is a read-through convenience
    # cache, not a correctness-bearing store -- see the elasticache module
    # for why.
    _cache_confirmation(event_id, slot_id, booking_id)

    return {"payment_succeeded": True, "booking_id": booking_id}


def _call_payment_gateway_stub(credentials, amount_cents):
    """Placeholder -- wire up your real gateway's SDK/HTTP call here."""
    return True


def _cache_confirmation(event_id, slot_id, booking_id):
    """Placeholder Redis write -- use redis-py or your preferred client."""
    pass
