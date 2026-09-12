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

      # node_pool: the cluster's GPU allow-list = the Cosmos 3 Generator SUPPORT
      # MATRIX, verbatim from docs.nvidia.com/nim/cosmos/3.0.0/support-matrix.html.
      # The Generator requires Hopper+ (CC >= 9.0) — an ARCHITECTURE floor, not just
      # memory: A100 (80 GB) has the VRAM but is Ampere and unsupported; L40S/g6e
      # (Ada, CC 8.9) is likewise excluded. Validated SKUs → AWS families:
      #   g7e       RTX PRO 6000 Blackwell   96 GB   (1 GPU = nano only)
      #   p5        H100-80GB                80 GB   (1 GPU = nano only)
      #   p5en      H200                    141 GB   (super fp8, needs >= 121 GiB)
      #   p6-b200   B200                    192 GB   (super bf16, needs >= 150 GiB)
      # Listing all four lets Karpenter pick the cheapest that has capacity in your
      # account, across families AND AZs. nano usually lands on the 1-GPU g7e.2xlarge
      # or p5.4xlarge; raising min_gpu_memory_gib (below) routes super to H200/B200.
      node_pool = { instance_families = ["g7e", "p5", "p5en", "p6-b200"] }

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

        # The capacity gate: declare the VRAM need and Karpenter picks the cheapest
        # supported family/size that clears it. nano = >= 79 GiB (fits a single
        # g7e / p5 / H200 / B200). For super, raise this to 121 (fp8 → H200/B200) or
        # 150 (bf16 → B200 only), or set gpu_count > 1 to tensor-parallel across
        # smaller cards. (Set node_selection.instance_types to hard-pin instead.)
        node_selection = { min_gpu_memory_gib = 79 }

        # NIM_MODEL_VARIANT selects the size (nano 8B / super 32B) within the cosmos3
        # image. (The image renamed this from NIM_MODEL_SIZE; the running container
        # rejects NIM_MODEL_SIZE at boot with "no longer supported".)
        env = { NIM_MODEL_VARIANT = "nano" }

        # Restrict the internet-facing NLB to the deployer's IP. The internet-facing
        # NLB otherwise accepts 0.0.0.0/0 — see the module README "Networking /
        # access control" for internal-only or explicit-open alternatives.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
      }
    }
  }
}
