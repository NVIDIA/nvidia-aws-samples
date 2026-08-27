# ─────────────────────────────────────────────────────────────────────────────
# nvidia-alpamayo-on-aws — Alpamayo 1.5 on SageMaker over HTTP
#
# Deploys the NVIDIA Alpamayo 1.5 NIM as a managed Amazon SageMaker real-time
# endpoint. SageMaker's invocation contract is HTTP-only (POST /invocations +
# GET /ping), so the module wraps the container with its Caddy shim, which maps
# /ping → /v1/health/ready and /invocations → /v1/infer (via shim_config below).
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "alpamayo"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = var.ngc_secret_name != null ? {
    secret_arn      = data.aws_secretsmanager_secret.ngc[0].arn
    secret_json_key = "access-key"
    } : {
    api_key = var.ngc_api_key
  }

  sagemaker_endpoints = {
    nim = {
      alpamayo = {
        source_image_uri = "nvcr.io/nim/nvidia/alpamayo-1-5-10b:1.0.0"
        # ml.g6e.xlarge = 1× L40S (48 GB) — the SageMaker analogue of the EKS
        # g6e.xlarge examples, for an apples-to-apples comparison.
        instance_type = "ml.g6e.xlarge"

        # Route SageMaker's /invocations to Alpamayo's trajectory endpoint.
        # /ping → /v1/health/ready is the shim default and already matches;
        # caddy_backend_port auto-detects (8000). The shim's default infer
        # target is /v1/chat/completions (which Alpamayo also serves for Q&A).
        shim_config = {
          infer_path = "/v1/infer"
        }
      }
    }
  }
}
