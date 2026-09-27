variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "git_branch" {
  description = "Branch of your frontend repo that Amplify tracks for auto-deploys."
  type        = string
  default     = "main"
}

variable "api_invoke_url" {
  type = string
}

variable "cognito_user_pool_id" {
  type = string
}

variable "cognito_client_id" {
  type = string
}

variable "web_acl_id" {
  description = "ARN of the WAFv2 Web ACL (CLOUDFRONT scope, us-east-1) to attach to this distribution."
  type        = string
}
