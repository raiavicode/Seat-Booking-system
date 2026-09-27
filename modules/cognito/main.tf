############################################################
# MODULE: cognito
#
# WHAT THIS IS:
#   Handles Arrows 1-2 in the diagram: Client App -> Amplify
#   (frontend auth SDK) -> Cognito (issues the actual tokens).
#   The User Pool is the identity store (who your users are);
#   the User Pool Client is the "application" registration that
#   your frontend uses to talk to that pool.
############################################################

resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-users-${var.environment}"

  # Users sign in with email, not a separate username field --
  # simplest option for a consumer booking app. Switch to
  # ["phone_number"] or leave both if you need SMS-based auth
  # too.
  username_attributes = ["email"]

  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  # MFA left optional rather than required, so you don't force
  # every user through an SMS/TOTP flow just to book a seat --
  # flip to "ON" if this ever handles higher-stakes bookings
  # (e.g. large group/corporate reservations) where account
  # takeover is a bigger concern.
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  tags = merge(var.tags, {
    Component          = "client-auth"
    ArchitectureArrows = "1,2"
  })
}

resource "aws_cognito_user_pool_client" "app" {
  name         = "${var.project_name}-app-client-${var.environment}"
  user_pool_id = aws_cognito_user_pool.this.id

  # No client secret: this client is used by a public frontend
  # (a browser/mobile app), which can't keep a secret safe
  # anyway. Confidential clients (server-to-server) should be a
  # SEPARATE app client with generate_secret = true.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",       # standard secure browser/mobile login
    "ALLOW_REFRESH_TOKEN_AUTH",  # lets sessions refresh without re-login
  ]

  # Tokens expire in hours, not days -- balances user convenience
  # (not logging in constantly) against limiting the blast radius
  # of a stolen access token.
  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# The Identity Pool is what lets authenticated users get
# temporary AWS credentials (used if your frontend needs to
# call AWS services directly, e.g. uploading to S3 -- not
# strictly required if all access goes through API Gateway,
# but included since Amplify projects commonly wire this up).
resource "aws_cognito_identity_pool" "this" {
  identity_pool_name               = "${var.project_name}-identity-${var.environment}"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.app.id
    provider_name            = aws_cognito_user_pool.this.endpoint
    server_side_token_check = false
  }

  tags = var.tags
}
