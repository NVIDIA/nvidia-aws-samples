terraform {
  # Terraform Actions (action_trigger lifecycle) require >= 1.14.
  # >= 1.15 is a hard requirement: 1.15 shipped the fix for
  # https://github.com/hashicorp/terraform/issues/37975 ("Actions not
  # respecting resource dependencies", merged in PR #38668). Without that
  # fix, action_trigger fires actions BEFORE the resource's `depends_on`
  # chain resolves — in practice this races the module's IAM propagation
  # `time_sleep` and produces a CodeBuild build that dies before the
  # container starts, leaving no logs. Silent failure with no debuggable
  # signal. Not worth supporting older versions.
  required_version = ">= 1.15"

  required_providers {
    aws = {
      # aws_codebuild_start_build action type requires AWS provider >= 6.0.
      # resource-level region = var.region requires v6 child-module pattern.
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      # Used to zip shim/ before uploading to S3 for CodeBuild
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
    random = {
      # Used to generate the S3 bucket name suffix (replaces s3_bucket_suffix variable)
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    time = {
      # Used for IAM propagation delay before triggering CodeBuild
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}
