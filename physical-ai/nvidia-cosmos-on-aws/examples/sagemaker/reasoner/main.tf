# ─────────────────────────────────────────────────────────────────────────────
# nvidia-cosmos-on-aws — Cosmos 3 Reasoner (SageMaker real-time)
#
# Deploys the NVIDIA Cosmos 3 Reasoner NIM — the vision-language "understanding"
# tower of Cosmos 3, exposed standalone (text in → text out) — as an Amazon
# SageMaker real-time endpoint, sourced from the terraform-aws-nim module.
#
# This is the CHEAP counterpart to the Generator: the Reasoner is a ~8B VLM that
# fits comfortably on a single GPU. It's a fast end-to-end validation of the
# Cosmos NIM path.
#
# Real-time (not async): the Reasoner returns text, which is small and fast —
# well within SageMaker's real-time 60s / payload limits. (The video Generator
# needs async; the Reasoner does not.)
#
# No infer_path override: the Reasoner serves the standard VLM contract
# (POST /v1/chat/completions), which is exactly the shim's default — so the
# Caddy shim's /invocations → /v1/chat/completions rewrite works unchanged.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "cosmos-reason"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Path A (Secrets Manager, recommended) when ngc_secret_name is set.
  # Path B (inline api_key, dev-only) when ngc_api_key is set. Exactly one required.
  # The image is public GA, so a standard nvapi-* NGC key works. CodeBuild syncs
  # the image with it.
  ngc_credentials = var.ngc_secret_name != null ? {
    secret_arn      = data.aws_secretsmanager_secret.ngc[0].arn
    secret_json_key = "access-key"
    } : {
    api_key = var.ngc_api_key
  }

  sagemaker_endpoints = {
    nim = {
      cosmos3-reasoner = {
        source_image_uri = var.source_image_uri

        # Cosmos 3 is one image serving both towers; these env vars select the
        # Reasoner tower (nano tier). Passed through via the module's
        # sagemaker_endpoints.nim `env` field.
        env = {
          NIM_MODEL_TYPE    = "reasoner"
          NIM_MODEL_VARIANT = "nano"
        }

        # Cosmos-Reason-class VLM (~8B): single-GPU, 24 GB VRAM minimum. G7e
        # (RTX PRO 6000 Blackwell, 96 GB) has ample headroom. SageMaker's smallest
        # G7e size is .2xlarge (no .xlarge). This is the cheap, single-GPU Reasoner
        # path — not a multi-GPU P5 node.
        instance_type = "ml.g7e.2xlarge"

        # Real-time endpoint (default): text output is fast and small.
        endpoint_type = "realtime"

        # No shim_config.infer_path override — the Reasoner serves the standard
        # VLM path (/v1/chat/completions), which is the shim's default.
      }
    }
  }
}
