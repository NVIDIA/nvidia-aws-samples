data "aws_region" "current" {}

data "aws_secretsmanager_secret" "ngc" {
  name = var.ngc_secret_name
}
