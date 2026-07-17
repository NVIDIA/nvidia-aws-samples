module "terraform-aws-nim" {
  source = "../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = {
    secret_arn = data.aws_secretsmanager_secret.ngc.arn
  }

  # ---------------------------------------------------------------------------
  # SageMaker: NIM + open-weight endpoints
  # ---------------------------------------------------------------------------

  sagemaker_endpoints = {
    nim = {
      # NIM — pre-optimized NGC container, automatic GPU profile selection
      llama-nemotron-nano-8b = {
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        instance_type              = "ml.g6e.xlarge"
        endpoint_type              = "realtime"
        enable_model_profile_cache = true
        container_startup_timeout  = 1200
      }
    }
    open_weight = {
      # Open-weight — raw HuggingFace weights served via vLLM
      # NVIDIA's Llama-Nemotron is under the NVIDIA Open Model License — no HF token required.
      llama-nemotron-nano-8b = {
        model_id                  = "nvidia/Llama-3.1-Nemotron-Nano-8B-v1"
        model_source              = "huggingface"
        instance_type             = "ml.g6e.xlarge"
        enable_vllm_recipe        = true
        container_startup_timeout = 1800
      }
    }
  }

  # ---------------------------------------------------------------------------
  # EKS: one cluster, NIM + open-weight deployments sharing the node.
  # Uses `g6e.12xlarge` (4× L40S) because two deployments need two GPUs minimum.
  # Single-deployment examples (`eks/nim`, `eks/open-weight`) use `g6e.xlarge`.
  # ---------------------------------------------------------------------------

  eks_clusters = {
    llama-nemotron-nano-8b = {
      vpc_id                  = aws_vpc.main.id
      private_subnet_ids      = aws_subnet.private[*].id
      public_subnet_ids       = aws_subnet.public[*].id
      instance_type           = "g6e.12xlarge"
      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id
    }
  }

  eks_deployments = {
    nim = {
      # NIM path — NGC container image, Helm deploy
      llama-nemotron-nano-8b = {
        cluster_key                = "llama-nemotron-nano-8b"
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        enable_model_profile_cache = true
        helm_chart_version         = "2.0.3"
      }
    }
    open_weight = {
      # Open-weight path — raw HuggingFace weights, vLLM serve
      # Shares the same S3 weight download as the SageMaker open-weight endpoint above.
      # namespace is set explicitly so NIM and open-weight don't share the same namespace
      # on the same cluster — separate namespaces ensure clean NLB teardown on destroy.
      llama-nemotron-nano-8b = {
        cluster_key  = "llama-nemotron-nano-8b"
        namespace    = "llama-nemotron-nano-8b-ow"
        model_id     = "nvidia/Llama-3.1-Nemotron-Nano-8B-v1"
        model_source = "huggingface"
      }
    }
  }
}
