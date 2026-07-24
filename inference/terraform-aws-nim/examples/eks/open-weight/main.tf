module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  eks_clusters = {
    llama-nemotron-nano-8b = {
      vpc_id                  = aws_vpc.main.id
      private_subnet_ids      = aws_subnet.private[*].id
      public_subnet_ids       = aws_subnet.public[*].id
      instance_type           = "g6e.xlarge"
      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id
      # Installs KEDA + kube-prometheus-stack + DCGM exporter cluster-wide so
      # any deployment on this cluster can opt into autoscaling below.
      enable_autoscaling = true
    }
  }

  # Llama-3.1-Nemotron-Nano-8B-v1 is under the NVIDIA Open Model License (with Llama 3.1
  # Community License as additional terms) — no HF token needed.
  # Set hf_secret_name only for gated models (e.g. Meta Llama base releases).
  hf_credentials = var.hf_secret_name != null ? {
    secret_arn = data.aws_secretsmanager_secret.hf[0].arn
  } : null

  eks_deployments = {
    open_weight = {
      llama-nemotron-nano-8b = {
        cluster_key  = "llama-nemotron-nano-8b"
        model_id     = "nvidia/Llama-3.1-Nemotron-Nano-8B-v1"
        model_source = "huggingface"

        # Restrict the internet-facing NLB to the deployer's IP (module validation
        # requires this when load_balancer_internal = false).
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        # KEDA ScaledObject scales this vLLM deployment between 1 and 3 replicas
        # based on vllm:kv_cache_usage_perc (auto-derived for open_weight — vLLM
        # exposes this natively on /metrics with the vllm: prefix, distinct from
        # NIM's chart-stripped gpu_cache_usage_perc). See the README "Autoscaling"
        # section for the load-test procedure.
        autoscaling = {
          min_replicas = 1
          max_replicas = 3
        }
      }
    }
  }
}
