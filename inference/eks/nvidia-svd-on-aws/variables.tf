variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set. SVD-supported g6e capacity is best in us-east-1, us-east-2, us-west-2."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  default     = null
  description = "Name of the AWS Secrets Manager secret containing the NGC API key. Required for Path A (Secrets Manager); leave null for Path B (inline api_key). The NGC account must be approved for the 'AI for Media Private Access Program' which gates the SVD image."
}

variable "ngc_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NGC API key as a raw string (Path B — inline). When set, ngc_secret_name is ignored and the value flows into Terraform state. Use only for local dev / short-lived POCs; prefer Path A (secret_arn) for anything shared. Exactly one of ngc_secret_name / ngc_api_key must be set."

  validation {
    condition     = (var.ngc_secret_name != null) != (var.ngc_api_key != null)
    error_message = "Exactly one of ngc_secret_name (Path A, Secrets Manager) or ngc_api_key (Path B, inline) must be set — not both, not neither."
  }
}
