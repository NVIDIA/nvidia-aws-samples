# ---------------------------------------------------------------------------
# AWS identity
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Credentials from Secrets Manager
#
# Only instantiated when the corresponding secret_arn is provided within the
# credential object. Users create these secrets before first apply — the module
# reads but never creates or updates secrets.
# ---------------------------------------------------------------------------

data "aws_secretsmanager_secret_version" "ngc_api_key" {
  count     = var.ngc_credentials != null && var.ngc_credentials.secret_arn != null ? 1 : 0
  secret_id = var.ngc_credentials.secret_arn
}

# Future PR: hf_token is reserved for the custom NIM build path (enable_asset_build).
# Kept gated to avoid breaking callers who pass hf_credentials.secret_arn.
data "aws_secretsmanager_secret_version" "hf_token" {
  count     = var.hf_credentials != null && var.hf_credentials.secret_arn != null ? 1 : 0
  secret_id = var.hf_credentials.secret_arn
}
