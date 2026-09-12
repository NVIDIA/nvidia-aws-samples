module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = {
    secret_arn      = data.aws_secretsmanager_secret.ngc.arn
    secret_json_key = "access-key"
  }

  eks_clusters = {
    llama-nemotron-nano-8b = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id
      # GPU allow-list: Llama-Nemotron-8B fits a single L40S (g6e). Karpenter picks
      # the cheapest g6e size with capacity; gpu_count defaults to 1 → g6e.xlarge.
      node_pool               = { instance_families = ["g6e"] }
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

  eks_deployments = {
    nim = {
      llama-nemotron-nano-8b = {
        cluster_key                = "llama-nemotron-nano-8b"
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        enable_model_profile_cache = true
        helm_chart_version         = "2.0.3"

        # node_selection = this NIM's VRAM floor (~16 GB weights + KV headroom). Note
        # the cluster node_pool is pinned to one family (g6e) BECAUSE
        # enable_model_profile_cache pre-builds the profile for a SPECIFIC GPU — a
        # multi-family pool would make the cached profile ambiguous. This NIM's own
        # supported families are g5/g6e (A10G/L40S) per its support matrix, so drop the
        # cache and widen node_pool to ["g5","g6e"] for the multi-family pattern. For
        # the full "let Karpenter pick the cheapest" demo, see examples/eks/open-weight.
        node_selection = { min_gpu_memory_gib = 20 }

        # Restrict the internet-facing NLB to the deployer's IP (module validation
        # requires this when load_balancer_internal = false).
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
        # KEDA ScaledObject scales this deployment between 1 and 3 replicas
        # based on NIM-native gpu_cache_usage_perc (auto-derived from nim_type=llm).
        # Under load, Karpenter provisions additional g6e.xlarge nodes as pods pend.
        # See the README "Autoscaling" section for how to drive load and verify.
        autoscaling = {
          min_replicas = 1
          max_replicas = 3
        }
      }
    }
  }
}
