data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Only instantiated when Path A (ngc_secret_name) is used. When Path B
# (inline ngc_api_key) is used, ngc_secret_name is null and this data source
# does not evaluate — so `terraform plan` succeeds without a Secrets Manager
# secret pre-existing in the account.
data "aws_secretsmanager_secret" "ngc" {
  count = var.ngc_secret_name != null ? 1 : 0
  name  = var.ngc_secret_name
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com/"
}
