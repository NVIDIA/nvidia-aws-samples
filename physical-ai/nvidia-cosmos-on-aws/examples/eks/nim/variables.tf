variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set. Ensure g7e (RTX PRO 6000 Blackwell) capacity and G-instance quota are available in your chosen region."
  default     = null
}

variable "ngc_secret_name" {
  type        = string
  default     = null
  description = "Name of the AWS Secrets Manager secret containing the NGC API key. Required for Path A (Secrets Manager); leave null for Path B (inline api_key). The Cosmos image is public GA (nvcr.io/nim/nvidia/cosmos3), so a standard nvapi-* NGC key works. CodeBuild uses this key to pull the image, so an invalid key makes apply fail at base-sync, not at plan."
}

variable "ngc_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NGC API key as a raw string (Path B — inline). When set, ngc_secret_name is ignored and the value flows into Terraform state. Use only for local dev / short-lived POCs; prefer Path A (secret_arn) for anything shared. Exactly one of ngc_secret_name / ngc_api_key must be set. A standard nvapi-* key works (public GA image)."

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
  description = "Cosmos 3 Generator NIM container image (public GA, video via POST /v1/infer). NIM_MODEL_SIZE (set in main.tf) selects nano (8B) vs super (32B). The standalone Reasoner is a SEPARATE image (nvcr.io/nim/nvidia/cosmos3-reasoner), not an env switch."
  default     = "nvcr.io/nim/nvidia/cosmos3:2.0.0"
}
