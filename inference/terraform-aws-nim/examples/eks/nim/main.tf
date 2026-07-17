module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = {
    secret_arn = data.aws_secretsmanager_secret.ngc.arn
  }

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

  eks_deployments = {
    nim = {
      llama-nemotron-nano-8b = {
        cluster_key                = "llama-nemotron-nano-8b"
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        enable_model_profile_cache = true
        helm_chart_version         = "2.0.3"
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
