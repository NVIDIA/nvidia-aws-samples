module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Llama-3.1-Nemotron-Nano-8B-v1 is under the NVIDIA Open Model License (with Llama 3.1
  # Community License as additional terms) — no HF token needed.
  # Set hf_secret_name only for gated models (e.g. Meta Llama base releases).
  hf_credentials = var.hf_secret_name != null ? {
    secret_arn = data.aws_secretsmanager_secret.hf[0].arn
  } : null

  sagemaker_endpoints = {
    open_weight = {
      # NVIDIA Llama-3.1-Nemotron-Nano-8B-v1 — standard Llama-family architecture, fits
      # easily on a single L40S (48 GB VRAM). NVIDIA-published, commercial-use OK, no
      # HF gating.
      # ml.g6e.xlarge = 1x L40S, 48 GB — fits 8B with comfortable headroom. Bump to
      # ml.g6e.12xlarge if you need tensor parallelism for a larger model. Avoid
      # ml.g5.* on SageMaker — default AMI ships older NVIDIA drivers.
      llama-nemotron-nano-8b = {
        model_id           = "nvidia/Llama-3.1-Nemotron-Nano-8B-v1"
        model_source       = "huggingface"
        instance_type      = "ml.g6e.xlarge"
        enable_vllm_recipe = true
      }

      # -- Large model example (tensor parallelism) --------------------------
      # Uncomment to deploy Nemotron-3-Nano-30B alongside the 9B endpoint.
      #
      # At BF16, 30B weights occupy ~60 GB — more than a single GPU's VRAM.
      # ml.g5.12xlarge has 4x A10G (96 GB total). tensor-parallel-size = "4"
      # splits the model across all 4 GPUs. Without it, vLLM defaults to
      # tensor_parallel_size=1, the container OOMs, and the endpoint reaches
      # Failed. NIMs handle this automatically via NGC model profiles.
      # This is the key operational tradeoff of the open-weight path.
      #
      # nemotron-30b = {
      #   model_id      = "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16"
      #   model_source  = "huggingface"
      #   instance_type = "ml.g5.12xlarge"
      #   extra_args = {
      #     trust-remote-code    = "true"
      #     tensor-parallel-size = "4"  # 4x A10G = 96 GB total; 30B BF16 ~60 GB
      #   }
      # }

      # -- Public model (no HF token needed) ---------------------------------
      # qwen-7b = {
      #   model_id      = "Qwen/Qwen2.5-7B-Instruct"
      #   model_source  = "huggingface"
      #   instance_type = "ml.g5.2xlarge"
      #   extra_args    = { max-model-len = "8192" }
      # }

      # -- NGC model ---------------------------------------------------------
      # Replace hf_credentials with ngc_credentials above for NGC sources.
      # nemotron-70b = {
      #   model_id      = "nvidia/llama-3.1-nemotron-70b-instruct:1.3"
      #   model_source  = "ngc"
      #   instance_type = "ml.p4d.24xlarge"
      #   extra_args    = { dtype = "bfloat16", max-model-len = "32768" }
      # }
    }
  }
}
