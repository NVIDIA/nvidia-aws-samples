data "aws_region" "current" {}

data "aws_secretsmanager_secret" "ngc" {
  count = var.ngc_secret_name != null ? 1 : 0
  name  = var.ngc_secret_name
}
