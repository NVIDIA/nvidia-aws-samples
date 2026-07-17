variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  description = "Name of the AWS Secrets Manager secret containing the NGC API key (plaintext). Required: NIM containers are pulled from nvcr.io and NGC authentication is mandatory."
}
