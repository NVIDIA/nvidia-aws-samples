variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set."
  default     = null
}

variable "hf_secret_name" {
  type        = string
  description = "Name of the AWS Secrets Manager secret containing the HuggingFace token. Required for gated models (e.g. Meta Llama). Leave null for public models (default)."
  default     = null
}
