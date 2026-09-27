terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # Pinned to a specific minor version range rather than left
      # fully open -- protects you from a future major-version
      # provider release silently changing a resource's required
      # arguments out from under this repo. Bump deliberately, not
      # by accident.
      version = "~> 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# CloudFront's WAF association must be created in us-east-1 regardless
# of which region the rest of this stack deploys into -- that's an
# AWS/CloudFront requirement, not a choice this repo makes. This
# aliased provider exists ONLY for that one resource (see
# aws_wafv2_web_acl.cloudfront in root main.tf).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = var.tags
  }
}
