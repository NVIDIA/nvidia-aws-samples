# ─────────────────────────────────────────────────────────────────────────────
# nvidia-cosmos-on-aws — SageMaker async variant
#
# Deploys the NVIDIA Cosmos 3 Generator NIM as an Amazon SageMaker ASYNC
# inference endpoint, sourced from the terraform-aws-nim module. SageMaker's
# contract is HTTP-only (/invocations + /ping), so the module wraps the NIM in
# the Caddy shim; the shim rewrites /invocations → the Cosmos inference path
# (/v1/infer) via shim_config.infer_path.
#
# Why async (not real-time): Cosmos video generation runs for minutes and
# returns a large base64 MP4 — both exceed real-time SageMaker limits (60s
# response / ~6 MB payload). Async has no 60s cap and writes the response to S3.
#
# This variant needs no Helm chart and exercises the shim's infer_path support
# (POST /invocations → /v1/infer) end-to-end.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "cosmos"
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
      cosmos3 = {
        source_image_uri = var.source_image_uri
        env              = { NIM_MODEL_VARIANT = "nano" } # generator size: nano (8B) / super (32B)

        # Cosmos 3 Generator/nano requires Hopper+ (CC >= 9.0) and >= 79 GiB
        # VRAM/device. ml.g7e.2xlarge (1× RTX PRO 6000 Blackwell, 96 GB) clears
        # that on a single GPU — the SageMaker match to the EKS g7e.2xlarge default.
        instance_type = "ml.g7e.2xlarge"

        # ASYNC: video generation is long-running with a large output payload.
        # Response is written to S3 under async_output_s3_prefix (default async-output/).
        endpoint_type = "async"

        # The Cosmos model is large; first-boot download + load can exceed the
        # default 600s health-check window. Bump toward the 3600s max so SageMaker
        # doesn't kill the container mid-load.
        container_startup_timeout = 3600

        # The shim (Caddy) rewrites POST /invocations → the NIM's inference path.
        # Cosmos serves POST /v1/infer (not the /v1/chat/completions default), so
        # set infer_path. /ping falls back to the shim's default health mapping,
        # which matches Cosmos's /v1/health/ready.
        shim_config = {
          infer_path = "/v1/infer"
        }
      }
    }
  }
}
