# Notes on `deployer-iam-policy.json`

This file has no comments in it on purpose -- AWS IAM rejects any policy
document containing fields it doesn't recognize (an early draft of this
policy had inline `_comment` keys, which would have made it invalid the
moment someone tried to actually attach it). Annotations live here instead.

- **Attach this to the IAM user/role that runs `terraform apply`.** It is
  intentionally broader than the runtime least-privilege policies defined
  inside the Terraform modules themselves -- those govern what the
  *deployed Lambdas* can do; this governs what the *deployer* can do.
- **`IAMForServiceRoles`**: scope `Resource` down to
  `arn:aws:iam::<account-id>:role/<project_name>-*` and
  `arn:aws:iam::<account-id>:policy/<project_name>-*` once you know your
  account ID and chosen `project_name`/`environment` values -- left broad
  here only because this is a static file and those are Terraform
  variables, not fixed values.
- **`EC2ForVPCLookup`**: read-only VPC/subnet lookups plus security-group
  management. This repo does **not** create or delete VPCs or subnets
  themselves, only references existing ones you provide.
- **`KMSForCustomerManagedKey`**: needed because this repo creates its own
  customer-managed KMS key (see `aws_kms_key.app` in root `main.tf`)
  rather than relying on AWS-owned default keys. DynamoDB, SQS, SNS,
  Secrets Manager, and CloudWatch Logs all request grants against this
  key on the deployer's behalf at apply time -- without `kms:CreateGrant`
  specifically, several resources will fail to create with a
  KMS-access-denied error that doesn't obviously point back to this
  policy as the cause.
