# Seat/Slot Booking Engine — Reference Architecture (Terraform)

This repo is the working implementation behind ["Who's Checking the Lock?"](#)
— a reference architecture for reliable, race-condition-free slot/seat
booking on AWS, built around a concrete example (cinema seat booking) but
applicable to any high-stakes allocation problem: delivery slots, GPU
inventory, energy grid capacity, or anything else where two requests can
race for the same finite resource.

**The core claim this repo proves out:** as autonomous agents start
making reservations and purchases on our behalf, race conditions stop
being edge cases a human notices and reports — they become invisible
failures at machine speed. The four reliability fixes below are what
"correct, even when nobody's watching" actually looks like in a real,
deployable system.

## The four reliability fixes (read this before anything else)

| # | Fix | Where |
|---|-----|-------|
| **Arrow 11** | DynamoDB — not Redis — is the single source of truth for lock status, closing a race where Search could show a seat as available when it was already locked. | `modules/dynamodb`, `lambda-src/lock-slot` |
| **Arrow 15** | Notifications fire from a DynamoDB Streams → SQS pipe, not a direct call from Process Payment — so a confirmation can never be sent for a write that hasn't actually committed. | `modules/async-notifications` |
| **Arrow 20** | Payment failure triggers immediate lock release via Step Functions' `Catch` block — not just a timeout. | `modules/step-functions` |
| **Arrow 21 / 23** | A 5-minute EventBridge sweep independently releases any lock that's expired, as a backup for when the immediate path (20) can't run — e.g. the Step Functions execution itself died. | `modules/async-notifications` (schedule), `lambda-src/release-lock` (sweep logic), root `main.tf` (wiring) |

Every module below that touches one of these is tagged in its own header
comment with the arrow number(s) it implements — search for
`ArchitectureArrows` if you want to trace the diagram to code directly.

## Repo structure

```
.
├── main.tf                  # Wires every module together, in build order
├── variables.tf              # Root-level inputs (see terraform.tfvars.example)
├── outputs.tf
├── versions.tf                # Provider/Terraform version pins
├── terraform.tfvars.example   # Copy to terraform.tfvars and fill in
├── backend.tf.example         # Copy to backend.tf for remote state
├── modules/
│   ├── iam/                   # Shared Lambda execution role
│   ├── secrets/                # Payment gateway credentials (Secrets Manager)
│   ├── dynamodb/                # THE reliability-critical data layer
│   ├── elasticache/              # Redis -- cache only, not authoritative
│   ├── cognito/                   # Auth (User Pool + Identity Pool)
│   ├── lambda-functions/           # All 5 Lambdas, wired to their permissions
│   ├── step-functions/              # The saga orchestrator (ASL + IAM)
│   ├── api-gateway/                  # REST API, Cognito authorizer, direct SFN integration
│   ├── frontend/                      # CloudFront + Amplify
│   ├── async-notifications/            # SQS, SNS, SES, EventBridge, the Streams pipe
│   └── observability/                   # Dashboard + alarms
└── lambda-src/
    ├── search/
    ├── lock-slot/
    ├── process-payment/
    ├── release-lock/
    └── notify/
```

## Prerequisites

- **Terraform** >= 1.7.0, **AWS provider** ~> 5.40 (see `versions.tf`)
- **An AWS account** with permissions to create IAM roles/policies,
  DynamoDB tables, Lambda functions, Step Functions, API Gateway,
  CloudFront, Amplify, ElastiCache, Cognito, SQS/SNS/SES, EventBridge,
  Secrets Manager, and CloudWatch. (If you want the exact minimum IAM
  policy for the identity running `terraform apply` itself, see
  `docs/deployer-iam-policy.json`.)
- **An existing VPC with at least 2 private subnets in different AZs.**
  This repo does not create a VPC for you. **Important gotcha:** those
  private subnets need a route to the internet (typically via a NAT
  Gateway) so the Process Payment Lambda can reach an external payment
  gateway's API. A fully isolated private subnet with no NAT will make
  every payment attempt fail with a timeout — this is the single most
  common "it deployed fine but nothing works" issue with this repo.
- **An email address you control**, for the SES sender identity.

### Rough cost estimate

Everything here is either serverless/on-demand (Lambda, DynamoDB,
API Gateway, Step Functions Express, SQS/SNS) or the smallest available
size (ElastiCache `cache.t4g.micro`). At low/dev traffic, expect **single-
digit dollars per month**, dominated by the ElastiCache node (~$12/mo if
left running continuously) and, if you don't already have one, a NAT
Gateway (~$32/mo + data processing — this is usually the single biggest
line item, and worth reusing an existing NAT Gateway if your VPC has one
rather than creating a new one). This is a rough order of magnitude for
a dev/demo deployment, not a production sizing estimate — always check
the [AWS Pricing Calculator](https://calculator.aws) against your actual
expected traffic before relying on this number.

## Deploy order

You don't need to run modules individually — `terraform apply` resolves
the real dependency graph automatically. This order is documented for
understanding, not for how you invoke Terraform:

1. **IAM, Secrets, DynamoDB, Cognito** — no dependencies on each other
2. **ElastiCache** — needs the VPC/subnet inputs
3. **Async notifications** — needs the DynamoDB Stream ARN
4. **Lambda functions** — needs outputs from all of the above
5. **Step Functions** — needs the 3 Lambda ARNs it orchestrates
6. **API Gateway** — needs the Cognito pool ARN and state machine ARN
7. **Frontend** — needs the API URL and Cognito client ID
8. **Cross-module wiring** (root `main.tf`) — SQS→Notify, EventBridge→Release Lock
9. **Observability** — references almost everything, so it's declared last

## Getting started

```bash
git clone <this-repo>
cd seat-booking-terraform

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your real VPC, subnet, and email values

# Optional but recommended beyond a personal sandbox:
cp backend.tf.example backend.tf
# edit backend.tf with a real S3 bucket + DynamoDB table you've already created

terraform init
terraform plan    # review what it's about to create
terraform apply
```

## Manual steps Terraform can't do for you

After `terraform apply` succeeds, three things still need a human:

1. **Verify the SES sender identity.** Check the inbox for whatever
   email you set as `ses_sender_address` and click AWS's verification
   link. Confirmations will silently fail to send until you do this.
2. **Set the real payment gateway secret value.** The Secrets Manager
   secret is created with a placeholder (see `modules/secrets`). Set
   the real value via:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id <secret_name from output> \
     --secret-string '{"api_key":"...", "webhook_secret":"..."}'
   ```
3. **Connect a real git repository to the Amplify app**, via the AWS
   console (Amplify → your app → connect a repo) — Terraform can
   declare the Amplify app and branch, but the initial repo connection
   for auto-deploys is a one-time manual step.

## Testing what you deployed

Three tests are worth running before you trust this in front of real
users — see the full test plan in the companion PDF guide for exact
steps, but at a minimum:

- **Happy path**: search → lock → pay → confirmation email arrives
- **Payment-failure compensation**: force a payment failure and confirm
  the seat becomes `AVAILABLE` again within seconds (proves Arrow 20)
- **Concurrency race**: fire two simultaneous lock requests for the same
  seat and confirm exactly one succeeds (proves the Arrow 11 fix — this
  is the test that would have caught the original bug this project fixes)

## Validation status (read this before trusting it blindly)

This repo has been:
- ✅ Written with resource arguments cross-checked against the AWS
  provider's documented schema
- ✅ Statically analyzed with [Checkov](https://www.checkov.io/) —
  **311 checks passed, 27 failed** (full detail in
  `docs/checkov-report.txt`). The 27 remaining are documented below,
  not silently ignored.
- ✅ Parsed with `terraform-config-inspect` (a real HCL2 parser) against
  the root module and all 11 submodules individually — every file
  parses with zero diagnostics. This confirms valid HCL syntax and
  structure throughout, though it's a lighter check than full
  `terraform validate`: it doesn't check resource arguments against the
  actual AWS provider schema or resolve cross-module variable/output
  wiring the way `validate` does.
- ✅ Internally audited for consistency: every module argument matches
  a declared variable, every cross-module output reference resolves,
  and every `var.X` used in a module is actually declared (see the
  Python consistency checks referenced in this repo's commit history
  if you want to re-run them yourself after making changes)

This repo has **not** been:
- ❌ Run through full `terraform validate` (requires network access to
  `registry.terraform.io` to download the AWS provider plugin, which
  the environment this was authored in doesn't have — only the
  lighter `terraform-config-inspect` syntax check above was possible)
- ❌ Actually applied against a live AWS account

**Practically:** review it like you would any infrastructure code from
the internet before running `apply` against an account that matters —
start in a fresh/sandbox account, not production.

### The 27 remaining Checkov findings, categorized

**Intentional architectural decisions (won't fix, and shouldn't):**
- `CKV_AWS_117` (Search/Lock Slot/Release Lock/Notify not in a VPC) —
  deliberate. Only Process Payment needs VPC access (to reach
  ElastiCache); putting the other four in a VPC would add cold-start
  latency and NAT costs for zero benefit. See the comment on
  `aws_lambda_function.process_payment` in `modules/lambda-functions/main.tf`.
- `CKV_AWS_120` / `CKV_AWS_225` (API Gateway caching) — this API
  returns booking results, which must never be served stale. Enabling
  cache here would be actively wrong, not just unoptimized.
- `CKV_AWS_374` (CloudFront geo restriction) — this is a public booking
  app with no inherent geographic restriction; "none" is the correct
  value, not a missed setting.

**Reasonable production hardening, out of scope for a reference repo:**
- `CKV_AWS_272` (Lambda code-signing) — requires setting up a Signer
  profile and a code-signing pipeline; real value for a team with a
  mature CI/CD process, disproportionate setup for a repo meant to be
  read and understood first.
- `CKV2_AWS_57` (Secrets Manager auto-rotation) — requires authoring a
  separate rotation Lambda specific to your payment gateway's API;
  there's no generic version of this to include here.
- `CKV2_AWS_51` (API Gateway client certificate auth) — a defense-in-depth
  option worth adding once you have real client applications whose
  certificates you can manage; premature for a reference implementation.
- `CKV_AWS_310` (CloudFront origin failover) — needs a second origin to
  fail over to, which means running the frontend in two places; a
  reasonable next step once this is real infrastructure, not before.
- `CKV_AWS_86` (CloudFront access logging to S3) — logging is already
  covered at the WAF layer (see `aws_wafv2_web_acl_logging_configuration`);
  full request-level CloudFront logs to S3 is worth adding if you need
  long-term raw log retention beyond what CloudWatch/WAF logs give you.
- `CKV_AWS_237` (API Gateway create-before-destroy) — a `lifecycle`
  block is present on `aws_api_gateway_rest_api.this`; Checkov's static
  analysis doesn't always detect this pattern correctly across a
  `jsonencode()`-heavy file. Verified by hand.
- `CKV2_AWS_4` (API Gateway stage logging level) — `logging_level` is
  set via `aws_api_gateway_method_settings`, a separate resource from
  the stage itself; this is the correct way to configure it, but
  Checkov's check specifically looks at the stage resource in
  isolation and doesn't always follow the cross-resource reference.
- `CKV_AWS_174` / `CKV2_AWS_42` (CloudFront custom SSL / TLS version) —
  only relevant once you attach a real custom domain with an ACM
  certificate; using CloudFront's default certificate (as this repo
  does) doesn't let you choose a minimum TLS policy.
- `CKV_AWS_259` (response headers policy enforces HSTS at the policy
  level) — HSTS *is* configured (see `security_headers_config` in
  `modules/frontend/main.tf`); this specific check looks for it
  declared in a different sub-block than the one Terraform's provider
  currently supports for this argument.
- `CKV_AWS_116` (DLQ on Search/Lock Slot/Process Payment) — these three
  are invoked *synchronously* (via Step Functions/API Gateway), where
  DLQs don't apply the way they do for the async-invoked Release Lock
  and Notify functions (which do have one). Retries and failure
  handling for synchronous invocations are the caller's (Step
  Functions') responsibility, handled via the `Retry`/`Catch` blocks
  in the state machine definition instead.

If you're hardening this for a real production deployment, the
code-signing and secrets-rotation items are the two I'd actually
prioritize picking up first.

## Teardown

```bash
terraform destroy
```

Runs in the reverse of the deploy order above automatically. Two things
Terraform won't clean up for you: the SES identity verification status
resets (harmless), and any data you manually put in DynamoDB/S3 outside
of what Terraform created is untouched by design.
