############################################################
# MODULE: iam
#
# WHAT THIS IS:
#   The shared trust policy and base execution role that every
#   Lambda function in this architecture assumes. Individual
#   permissions (DynamoDB access, Secrets Manager access, etc.)
#   are NOT granted here -- they live next to the resource they
#   grant access to (see modules/dynamodb, modules/secrets) and
#   get attached to this role from the root module. That keeps
#   "what can touch the slots table" answerable by reading one
#   file (modules/dynamodb/main.tf) instead of hunting through
#   a single giant IAM module.
############################################################

# Trust policy: WHO is allowed to assume this role. For Lambda,
# it's always the lambda.amazonaws.com service principal --
# this is boilerplate AWS requires, not something you should
# need to change.
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution" {
  name               = "${var.project_name}-lambda-exec-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

# Baseline CloudWatch Logs permissions every Lambda needs just
# to write its own logs -- without this, your functions will
# run but you'll have zero visibility into what they're doing.
# This is intentionally the AWS-managed policy rather than a
# hand-rolled one: it's maintained by AWS and covers exactly
# CreateLogGroup/CreateLogStream/PutLogEvents, nothing more.
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray tracing permissions (Arrow 13 / Arrow 25 -- every Lambda
# writes trace segments here so you get the distributed trace
# shown in the "Observability & Secrets" zone of the diagram).
# Also an AWS-managed policy for the same reason as above: it's
# a narrow, well-audited permission set AWS keeps up to date.
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Every Lambda in this repo has kms_key_arn set on its environment
# variables (customer-managed key instead of AWS's default), which
# means the Lambda SERVICE needs this role to be able to decrypt with
# that key at invoke time -- without this, functions fail at cold
# start with a KMS access-denied error, not something you'd catch by
# reading the function code itself.
data "aws_iam_policy_document" "kms_decrypt" {
  statement {
    sid    = "DecryptEnvVarsAndQueues"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      # GenerateDataKey is needed too, not just Decrypt -- any Lambda
      # that WRITES to a KMS-encrypted SQS queue (e.g. a dead_letter_config
      # target) needs this in addition to Decrypt, which only covers
      # reading/consuming.
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "kms_decrypt" {
  name   = "${var.project_name}-kms-decrypt-${var.environment}"
  role   = aws_iam_role.lambda_execution.id
  policy = data.aws_iam_policy_document.kms_decrypt.json
}
