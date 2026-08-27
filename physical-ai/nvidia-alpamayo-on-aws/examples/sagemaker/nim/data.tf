data "aws_region" "current" {}

# Only instantiated when Path A (ngc_secret_name) is used. When Path B
# (inline ngc_api_key) is used, ngc_secret_name is null and this data source
# does not evaluate.
data "aws_secretsmanager_secret" "ngc" {
  count = var.ngc_secret_name != null ? 1 : 0
  name  = var.ngc_secret_name
}
