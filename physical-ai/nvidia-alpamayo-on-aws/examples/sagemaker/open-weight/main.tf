# ─────────────────────────────────────────────────────────────────────────────
# nvidia-alpamayo-on-aws — Alpamayo 2 Super (open weights) on SageMaker
#
# Deploys the open-weight NVIDIA Alpamayo 2 Super model (nvidia/Alpamayo2-Super
# on HuggingFace) as a managed Amazon SageMaker real-time endpoint via the
# terraform-aws-nim module's open-weight path (weights fetched from HuggingFace
# to S3, served behind the endpoint).
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "alpamayo2"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Alpamayo 2 Super is gated under the OpenMDW-1.1 license — accept it at
  # huggingface.co/nvidia/Alpamayo2-Super and reference a token via hf_secret_name.
  hf_credentials = var.hf_secret_name != null ? {
    secret_arn = data.aws_secretsmanager_secret.hf[0].arn
  } : null

  sagemaker_endpoints = {
    open_weight = {
      alpamayo2 = {
        model_id     = "nvidia/Alpamayo2-Super"
        model_source = "huggingface"

        # 34B model — needs multi-GPU. ml.g6e.12xlarge = 4× L40S (192 GB),
        # sharded tensor-parallel across the instance's GPUs.
        instance_type = "ml.g6e.12xlarge"
        extra_args    = { "tensor-parallel-size" = "4" }
      }
    }
  }
}
