resource "random_id" "suffix" {
  byte_length = 4
}

# CodeBuild bucket — source zip (shim-source.zip)
resource "aws_s3_bucket" "codebuild" {
  region        = var.region
  bucket        = "${local.name_prefix}-codebuild-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-codebuild-${random_id.suffix.hex}"
  })
}

# NGC model profile cache — pre-cached model profiles for standard NIMs.
# Shared between SageMaker (aws s3 sync at startup) and EKS (S3 Files CSI — Phase 3).
# Only created when enable_model_profile_cache = true for at least one endpoint.
resource "aws_s3_bucket" "nim_cache" {
  count = local.any_cache_enabled ? 1 : 0

  region        = var.region
  bucket        = "${local.name_prefix}-nim-cache-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nim-cache-${random_id.suffix.hex}"
  })
}

resource "aws_s3_bucket_versioning" "nim_cache" {
  count = local.any_cache_enabled ? 1 : 0

  region = var.region
  bucket = aws_s3_bucket.nim_cache[0].id

  versioning_configuration {
    # Protects nim-cache/: a failed partial upload won't silently overwrite
    # a known-good set of NGC profile artifacts.
    status = "Enabled"
  }
}

# Lifecycle rule — expires cached profiles after model_profile_cache_retention_days.
# Handles orphaned prefixes from instance_type or endpoint key changes.
# Null retention = no rule created (objects persist until manually deleted).
resource "aws_s3_bucket_lifecycle_configuration" "nim_cache" {
  count = local.any_cache_enabled && var.model_profile_cache_retention_days != null ? 1 : 0

  region = var.region
  bucket = aws_s3_bucket.nim_cache[0].id

  rule {
    id     = "nim-cache-expiration"
    status = "Enabled"

    expiration {
      days = var.model_profile_cache_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.nim_cache]
}

# Model assets — open weight files (SageMaker), future: EKS weights.
# No "sagemaker" in name — shared across platforms. Explicit IAM grants used instead of
# relying on AmazonSageMakerFullAccess wildcard condition (which requires "sagemaker" in name).
# Only created when at least one open weight endpoint is configured.
resource "aws_s3_bucket" "model_assets" {
  count = local.any_weights_enabled ? 1 : 0

  region        = var.region
  bucket        = "${local.name_prefix}-model-assets-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-model-assets-${random_id.suffix.hex}"
  })
}

# SageMaker async inference response payloads
resource "aws_s3_bucket" "sagemaker_output" {
  region        = var.region
  bucket        = "${local.name_prefix}-sagemaker-output-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sagemaker-output-${random_id.suffix.hex}"
  })
}

# model_assets versioning — same rationale as nim_cache: a failed partial
# re-download of multi-GB open-weight artifacts by weight-fetch CodeBuild
# could silently corrupt an already-working weights prefix.
resource "aws_s3_bucket_versioning" "model_assets" {
  count = local.any_weights_enabled ? 1 : 0

  region = var.region
  bucket = aws_s3_bucket.model_assets[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Public-access blocks on all four module-managed buckets. Belt-and-suspenders
# on top of the consumer's account-level defaults, so this module is safe
# regardless of how the consumer AWS account is configured.
resource "aws_s3_bucket_public_access_block" "codebuild" {
  region                  = var.region
  bucket                  = aws_s3_bucket.codebuild.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "nim_cache" {
  count = local.any_cache_enabled ? 1 : 0

  region                  = var.region
  bucket                  = aws_s3_bucket.nim_cache[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "model_assets" {
  count = local.any_weights_enabled ? 1 : 0

  region                  = var.region
  bucket                  = aws_s3_bucket.model_assets[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "sagemaker_output" {
  region                  = var.region
  bucket                  = aws_s3_bucket.sagemaker_output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
