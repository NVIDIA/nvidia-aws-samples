variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set. Requires ml.g7e.2xlarge SageMaker endpoint quota in the chosen region."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  default     = null
  description = "Name of the AWS Secrets Manager secret containing your NGC API key. Required for Path A (Secrets Manager); leave null for Path B (inline api_key). CodeBuild uses this key to pull the Cosmos image from nvcr.io, so an invalid key makes apply fail at base-sync, not at plan."
}

variable "ngc_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NGC API key as a raw string (Path B — inline). When set, ngc_secret_name is ignored and the value flows into Terraform state. Use only for local dev / short-lived POCs. Exactly one of ngc_secret_name / ngc_api_key must be set."

  validation {
    condition = (
      (var.ngc_secret_name != null && trimspace(var.ngc_secret_name) != "")
      != (var.ngc_api_key != null && trimspace(var.ngc_api_key) != "")
    )
    error_message = "Exactly one of ngc_secret_name (Path A, Secrets Manager) or ngc_api_key (Path B, inline) must be set to a non-empty value — not both, not neither."
  }
}

variable "source_image_uri" {
  type        = string
  description = "Cosmos 3 Generator NIM container image (public GA, video via POST /v1/infer). NIM_MODEL_VARIANT (set in main.tf) selects nano (8B) vs super (32B). The standalone Reasoner is a SEPARATE image (nvcr.io/nim/nvidia/cosmos3-reasoner)."
  default     = "nvcr.io/nim/nvidia/cosmos3:2.0.0"
}
