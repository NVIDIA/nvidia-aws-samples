variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set. SVD-supported g6e capacity is best in us-east-1, us-east-2, us-west-2."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  description = "Name of the AWS Secrets Manager secret containing the NGC API key (plaintext). The NGC account must be approved for the 'AI for Media Private Access Program' which gates the SVD image."
}
