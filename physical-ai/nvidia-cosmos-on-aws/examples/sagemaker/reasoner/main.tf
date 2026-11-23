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
  ngc_credentials = try(trimspace(var.ngc_secret_name), "") != "" ? {
    secret_arn      = data.aws_secretsmanager_secret.ngc[0].arn
    secret_json_key = "access-key"
    } : {
    api_key = var.ngc_api_key
  }

  sagemaker_endpoints = {
    nim = {
      cosmos3-reasoner = {
        source_image_uri = var.source_image_uri # cosmos3-reasoner — a SEPARATE image from the generator

        # NIM_MODEL_SIZE selects the reasoner size (nano 8B / super 32B).
        env = { NIM_MODEL_SIZE = "nano" }

        # Reasoner nano (~8B VLM) runs on an L40S (48 GB, FP8) per the VLM support
        # matrix — so ml.g6e.2xlarge, far cheaper and more available than the
        # generator's g7e. (SageMaker's smallest g6e is .2xlarge.)
        instance_type = "ml.g6e.2xlarge"

        # Real-time endpoint (default): text output is fast and small.
        endpoint_type = "realtime"

        # No shim_config.infer_path override — the Reasoner serves the standard
        # VLM path (/v1/chat/completions), which is the shim's default.
      }
    }
  }
}
