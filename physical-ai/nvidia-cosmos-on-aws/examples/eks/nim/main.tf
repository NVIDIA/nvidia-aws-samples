# ─────────────────────────────────────────────────────────────────────────────
# nvidia-cosmos-on-aws — Terraform example
#
# Deploys the NVIDIA Cosmos 3 Generator NIM (world foundation model — text or
# image → generated video; no video input) to an EKS Auto Mode cluster on AWS,
# sourced from the terraform-aws-nim module.
#
# Cosmos 3 is a Mixture-of-Transformer world model with two towers: a Reasoner
# (vision-language, text output) and a Generator (world simulator, video output).
# This example deploys the GENERATOR (`cosmos3` image, HTTP `POST /v1/infer` →
# b64_video). The Reasoner ships as a separate NIM (cosmos3-reasoner).
#
# Validated end-to-end on EKS Auto Mode: g7e.2xlarge (1× RTX PRO 6000 Blackwell,
# 96 GB), public GA image, Generator/nano tier, text2video. See the README.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  # Local relative source during development so this example tests against local
  # terraform-aws-nim edits (not the published module). Before publishing, switch
  # to the pinned git source SVD uses:
  #   source = "git::https://github.com/NVIDIA/nvidia-aws-samples.git//inference/terraform-aws-nim?ref=main"
  source = "../../../../../inference/terraform-aws-nim"

  project_prefix = "cosmos"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Path A (Secrets Manager, recommended) when ngc_secret_name is set.
  # Path B (inline api_key, dev-only) when ngc_api_key is set. Exactly one is required.
  # The image is public GA (nvcr.io/nim/nvidia/cosmos3), so a standard nvapi-* NGC
  # key works. CodeBuild pulls the image with it.
  ngc_credentials = var.ngc_secret_name != null ? {
    secret_arn      = data.aws_secretsmanager_secret.ngc[0].arn
    secret_json_key = "access-key"
    } : {
    api_key = var.ngc_api_key
  }

  eks_clusters = {
    cosmos = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id

      # node_pool: the cluster's GPU allow-list. Cosmos 3 Generator needs Hopper+
      # (CC >= 9.0) AND >= 79 GiB/device for nano — an architecture floor, not just
      # memory (so VRAM alone isn't enough: A100 80GB has the memory but is Ampere
      # and unsupported). We pin the g7e family (RTX PRO 6000 Blackwell, 96 GB), an
      # explicitly-validated Cosmos 3 SKU and the cheapest single-GPU option that
      # clears the floor. Karpenter picks whichever g7e SIZE has capacity, across AZs.
      #   Generator/super (32B, >= 121-150 GiB/device) → set gpu_count > 1 for TP, or
      #   add p5/p5e families. See the README "Instance selection" section.
      node_pool = { instance_families = ["g7e"] }

      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id

      # Autoscaling intentionally NOT enabled: each replica is its own GPU node.
      # Scaling Cosmos horizontally is a deliberate, per-GPU-cost choice, not a
      # sample default. To opt in, set this true and add an `autoscaling` block to
      # the deployment below (KEDA will then add g7e nodes under load).
      enable_autoscaling = false
    }
  }

  # Cosmos 3 Generator NIM — omnimodal world foundation model, served over HTTP.
  #
  # Why nim_type = "custom" + no Helm chart:
  #   Cosmos is a world foundation model with NO published Helm chart (the cookbook
  #   explicitly says not to reuse another NIM's chart). So the module deploys it
  #   via its raw-kubectl Deployment+Service path — the same no-chart path SVD uses
  #   for gRPC, here with HTTP probes. Leave all helm_chart_* unset → raw manifest.
  #
  # Why protocol = "http":
  #   Cosmos serves REST on port 8000 (POST /v1/infer, GET /v1/health/*). The cosmos3
  #   image is the GENERATOR (video). The standalone Reasoner is a SEPARATE NIM image
  #   (nvcr.io/nim/nvidia/cosmos3-reasoner, /v1/chat/completions) — not an env switch.
  eks_deployments = {
    nim = {
      cosmos3 = {
        cluster_key      = "cosmos"
        source_image_uri = var.source_image_uri # public nvcr.io/nim/nvidia/cosmos3:2.0.0

        nim_type  = "custom" # no auto chart
        protocol  = "http"   # → raw manifest with httpGet probes (no chart supplied)
        port      = 8000
        gpu_count = 1 # Generator nano fits one RTX PRO 6000 (96 GB)

        # This NIM needs >= 79 GiB VRAM (Generator nano). Within the cluster's g7e
        # family that's the 96 GB RTX PRO 6000; Karpenter provisions the cheapest g7e
        # size with capacity that satisfies it. (Set instance_types to pin exactly.)
        node_selection = { min_gpu_memory_gib = 79 }

        # NIM_MODEL_SIZE selects the size (nano 8B / super 32B) within the cosmos3 image.
        env = { NIM_MODEL_SIZE = "nano" }

        # Restrict the internet-facing NLB to the deployer's IP. The internet-facing
        # NLB otherwise accepts 0.0.0.0/0 — see the module README "Networking /
        # access control" for internal-only or explicit-open alternatives.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
      }
    }
  }
}
