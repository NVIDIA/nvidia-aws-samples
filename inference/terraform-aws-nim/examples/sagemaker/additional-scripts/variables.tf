variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  description = "Name of the AWS Secrets Manager secret containing the NGC API key (plaintext)."
}

variable "remote_script_s3_uri" {
  type        = string
  description = "S3 URI of a pre-existing remote-test.sh script. Upload examples/scripts/remote-test.sh to your bucket first, then set this to e.g. s3://your-bucket/remote-test.sh."
}
