data "aws_region" "current" {}

data "aws_secretsmanager_secret" "hf" {
  count = var.hf_secret_name != null ? 1 : 0
  name  = var.hf_secret_name
}
