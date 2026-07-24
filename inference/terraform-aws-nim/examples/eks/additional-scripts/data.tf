data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_secretsmanager_secret" "ngc" {
  name = var.ngc_secret_name
}

data "http" "my_ip" {
  url = "https://checkip.amazonaws.com/"
}
