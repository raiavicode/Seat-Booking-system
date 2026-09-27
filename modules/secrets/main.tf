############################################################
# MODULE: secrets
#
# WHAT THIS IS:
#   Holds the payment gateway API credentials that "λ Process
#   Payment" reads at runtime (Arrow 22 in the diagram: Secrets
#   Mgr feeding the Process Payment / observability zone).
#
# WHY SECRETS MANAGER (vs. a Lambda environment variable):
#   Environment variables are visible to anyone with
#   lambda:GetFunctionConfiguration permission and show up
#   in plaintext in the Lambda console and in Terraform state
#   diffs. Secrets Manager keeps the actual secret VALUE out of
#   both -- Terraform only ever manages the secret's existence
#   and metadata here, never the live value (see the note on
#   the "ignore_changes" lifecycle block below).
############################################################

resource "aws_secretsmanager_secret" "payment_gateway" {
  name        = "${var.project_name}/payment-gateway/${var.environment}"
  description = "API key + webhook signing secret for the payment gateway used by the Process Payment Lambda."

  # Customer-managed key (passed in from root main.tf) rather than the
  # AWS-owned default key -- gives you key-level access policies and a
  # CloudTrail-visible audit trail of every decrypt, appropriate for
  # something holding payment gateway credentials.
  kms_key_id = var.kms_key_arn

  # How long a secret stays recoverable after you delete it,
  # before AWS permanently destroys it. 7 is the minimum AWS
  # allows; raise this in prod if "someone deleted this by
  # mistake" needs a longer recovery window.
  recovery_window_in_days = 7

  tags = merge(var.tags, {
    Component          = "observability-secrets"
    ArchitectureArrows  = "22"
  })
}

# This creates the secret's initial value as a PLACEHOLDER.
# You are meant to overwrite this in the AWS console or via the
# CLI (`aws secretsmanager put-secret-value`) with your real
# payment gateway credentials AFTER apply -- never commit real
# credentials into this repo or into a .tfvars file that gets
# checked into git.
resource "aws_secretsmanager_secret_version" "payment_gateway_placeholder" {
  secret_id = aws_secretsmanager_secret.payment_gateway.id
  secret_string = jsonencode({
    api_key        = "REPLACE_ME_AFTER_APPLY"
    webhook_secret = "REPLACE_ME_AFTER_APPLY"
  })

  # IMPORTANT: without this lifecycle block, every `terraform
  # apply` after you've manually rotated the real secret value
  # would try to stomp it back to the placeholder above, since
  # Terraform doesn't know the real value changed out-of-band.
  # This tells Terraform "once created, never touch the value
  # again through this resource."
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# IAM policy granting read-only access to just this one secret
# -- deliberately scoped to a single resource ARN rather than
# "secretsmanager:GetSecretValue on *", so a compromised Process
# Payment function can't go read every other secret in the
# account.
data "aws_iam_policy_document" "payment_gateway_read" {
  statement {
    sid       = "ReadPaymentGatewaySecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.payment_gateway.arn]
  }
}

resource "aws_iam_policy" "payment_gateway_read" {
  name        = "${var.project_name}-payment-secret-read-${var.environment}"
  description = "Read-only access to the payment gateway secret"
  policy      = data.aws_iam_policy_document.payment_gateway_read.json
}
