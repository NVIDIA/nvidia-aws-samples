data "aws_region" "current" {}

data "aws_secretsmanager_secret" "ngc" {
  count = try(trimspace(var.ngc_secret_name), "") != "" ? 1 : 0
  name  = var.ngc_secret_name
}
