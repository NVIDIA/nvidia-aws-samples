# ─────────────────────────────────────────────────────────────────────────────
# nvidia-alpamayo-on-aws — Alpamayo 2 Super (open weights) on EKS
#
# Deploys the open-weight NVIDIA Alpamayo 2 Super model (nvidia/Alpamayo2-Super
# on HuggingFace) to an EKS Auto Mode cluster via the terraform-aws-nim module's
# open-weight path (weights fetched from HuggingFace, served on the cluster).
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "alpamayo2"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Alpamayo 2 Super is gated under the OpenMDW-1.1 license. Accept it at
  # huggingface.co/nvidia/Alpamayo2-Super, then reference a token that has
  # accepted the terms via hf_secret_name.
  hf_credentials = var.hf_secret_name != null ? {
    secret_arn = data.aws_secretsmanager_secret.hf[0].arn
  } : null

  eks_clusters = {
    alpamayo2 = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id

      # Alpamayo 2 Super is a 34B model (32B VLM backbone + 2.3B action decoder),
      # so it needs multi-GPU. g6e.12xlarge = 4× L40S (192 GB total), sharded
      # tensor-parallel across the node's GPUs.
      instance_type = "g6e.12xlarge"

      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id
    }
  }

  eks_deployments = {
    open_weight = {
      alpamayo2 = {
        cluster_key  = "alpamayo2"
        model_id     = "nvidia/Alpamayo2-Super"
        model_source = "huggingface"

        # Shard the 34B model across the 4 L40S on the node.
        gpu_count  = 4
        extra_args = { "tensor-parallel-size" = "4" }

        # Restrict the internet-facing NLB to the deployer's IP.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
      }
    }
  }
}
