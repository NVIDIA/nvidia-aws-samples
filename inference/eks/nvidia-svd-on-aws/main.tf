# ─────────────────────────────────────────────────────────────────────────────
# nvidia-svd-on-aws — Terraform example
#
# Deploys the NVIDIA Maxine Synthetic Video Detector (SVD) NIM to an EKS Auto
# Mode cluster on AWS, sourced from the terraform-aws-nim module.
#
# Status (2026-07-16): Live. End-to-end validated on g4dn.2xlarge (T4) —
# bundled SVD sample scored 99.41% SYNTHETIC. Pod autoscaling verified 1↔2
# under sustained load with zero probe-timeout restarts.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  # Local relative source during development so this example tests against local
  # terraform-aws-nim edits (not the published module). Before publishing, switch back to:
  #   source = "git::https://github.com/NVIDIA/nvidia-aws-samples.git//inference/terraform-aws-nim?ref=main"
  source = "../../terraform-aws-nim"

  project_prefix = "svd"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  # Path A (Secrets Manager, recommended) when ngc_secret_name is set.
  # Path B (inline api_key, dev-only) when ngc_api_key is set. Exactly one is required.
  ngc_credentials = var.ngc_secret_name != null ? {
    secret_arn      = data.aws_secretsmanager_secret.ngc[0].arn
    secret_json_key = "access-key"
    } : {
    api_key = var.ngc_api_key
  }

  eks_clusters = {
    svd = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id

      # SVD requires GPUs with NVENC/NVDEC. A100/H100/B100 are NOT supported.
      # See the README for the full instance selection discussion.
      #
      # g4dn.2xlarge (T4, 16 GB VRAM) is the default:
      #   * Explicitly listed on the SVD support matrix
      #   * ~$0.75/hr on-demand vs ~$2.24/hr for g6e.2xlarge (~66% cheaper)
      #   * Best on-demand availability in us-east-1 across AZs
      #   * Tradeoff: ~5x slower per video than L40S (~24s vs ~5s on the sample clip)
      #
      # node_pool lists ALL of SVD's supported GPU families (T4/A10G/L4/L40S). Karpenter
      # provisions whichever has capacity across AZs — a direct hedge against GPU scarcity,
      # since SVD runs functionally on any of them (throughput differs: L40S fastest, T4
      # cheapest/most-available). Narrow to one family, or add a deployment node_selection,
      # to pin a specific GPU.
      #   SVD v2 adds datacenter GPUs (A100/H100/H200/B200) — append p4d/p5/p5e/p6 then.
      node_pool = { instance_families = ["g4dn", "g5", "g6", "g6e"] }

      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id

      # Installs KEDA + kube-prometheus-stack + DCGM exporter cluster-wide so
      # the SVD deployment below can opt into pod autoscaling. Adds ~5 min to
      # first apply. Zero-cost when idle (small operator pods only).
      enable_autoscaling = true
    }
  }

  # gRPC NIM example: deploys NVIDIA Maxine Synthetic Video Detector (SVD).
  #
  # Why nim_type = "custom":
  #   Maxine NIMs ship no Helm chart on NGC today (docker-run only). The module's
  #   raw-kubectl path handles this — when protocol = "grpc", chart info is
  #   NOT required, the module emits a Deployment + Service via kubectl.
  #
  # Why protocol = "grpc":
  #   Media NIMs serve inference over gRPC (port 8001) — HTTP is admin/health
  #   only. See the terraform-aws-nim DEVELOPER_REFERENCE.md "Inference Protocols"
  #   section for the full background.
  #
  # NGC entitlement:
  #   SVD requires AI for Media Private Access Program entitlement. base-sync
  #   CodeBuild will fail with `Payment Required` from nvcr.io if your NGC key
  #   lacks that entitlement. See README "Troubleshooting" for resolution.
  eks_deployments = {
    nim = {
      svd = {
        cluster_key      = "svd"
        source_image_uri = "nvcr.io/nim/nvidia/synthetic-video-detector:latest"
        nim_type         = "custom"
        protocol         = "grpc"
        # port defaults to 8001 (gRPC convention for Maxine NIMs)

        # node_selection = SVD's VRAM floor (the capacity gate), complementing the
        # cluster node_pool's NVENC/NVDEC family list (the architecture gate) — the
        # two gates together. T4's 16 GB clears 15, so all four families stay
        # eligible and Karpenter still picks the cheapest (g4dn/T4). Rendered into
        # the pod's nodeAffinity at deploy time.
        node_selection = { min_gpu_memory_gib = 15 }

        # Restrict the inference NLB to the deployer's IP. The internet-facing NLB
        # otherwise accepts traffic from 0.0.0.0/0 (see the module README's
        # "Networking / access control" section for the alternatives — internal-only
        # LB, or explicit ["0.0.0.0/0"] to opt into an open endpoint).
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        # KEDA ScaledObject scales SVD 1→3 replicas based on
        # DCGM_FI_DEV_GPU_UTIL (auto-derived because nim_type=custom). SVD
        # processes one video per GPU, so each concurrent stream needs its
        # own pod — without autoscaling, concurrent tenants contend on the
        # same GPU. scale_down_delay=180 (3 min) is tuned for bursty video
        # workloads; module default is 600s. See the vendored module's
        # "Autoscaling on EKS" README section for tuning guidance.
        autoscaling = {
          min_replicas     = 1
          max_replicas     = 3
          scale_down_delay = 180
        }
      }
    }
  }
}
