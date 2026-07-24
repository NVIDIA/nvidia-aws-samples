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
    svd = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id
      # g4dn.2xlarge = T4 (16GB VRAM), 8 vCPU, 32 GB RAM. Meets SVD's minimums
      # per NVIDIA support matrix (T4 explicitly listed; NVENC/NVDEC present).
      # ~3x cheaper than g6e.2xlarge on-demand + best availability of any GPU
      # family in us-east-1 (g4dn = 2019, least contested capacity pool).
      # Tradeoff: T4 ~5x slower per video than L40S; acceptable for bursty POC,
      # not for latency-critical prod.
      instance_type           = "g4dn.2xlarge"
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

  # gRPC NIM example: deploys NVIDIA Maxine Synthetic Video Detector (SVD).
  #
  # Why nim_type = "custom":
  #   Maxine NIMs ship no Helm chart on NGC today (docker-run only). The module's
  #   raw-kubectl path handles this — when protocol = "grpc", chart info is
  #   NOT required, the module emits a Deployment + Service via kubectl.
  #
  # Why protocol = "grpc":
  #   Media NIMs serve inference over gRPC (port 8001) — HTTP is admin/health
  #   only. See the root README "Inference protocols" section and
  #   DEVELOPER_REFERENCE.md "Inference Protocols and the Choices in This Module"
  #   for the full background.
  #
  # NGC entitlement:
  #   SVD requires private-access program entitlement on your NGC account.
  #   The base_sync CodeBuild step will fail with an unauthorized error if
  #   your NGC API key doesn't have SVD access.
  eks_deployments = {
    nim = {
      svd = {
        cluster_key      = "svd"
        source_image_uri = "nvcr.io/nim/nvidia/synthetic-video-detector:latest"
        nim_type         = "custom"
        protocol         = "grpc"
        # port defaults to 8001 (gRPC convention for Maxine NIMs)

        # Restrict the internet-facing NLB to the deployer's IP. Required by module
        # validation when load_balancer_internal = false. Use ["0.0.0.0/0"] to
        # opt into a fully open endpoint.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        # KEDA ScaledObject scales SVD between 1 and 3 replicas based on
        # DCGM_FI_DEV_GPU_UTIL (auto-derived because nim_type=custom — Maxine
        # NIMs expose only GPU/process telemetry on /v1/metrics, no request-load
        # signal). Since SVD processes one video per GPU, each concurrent stream
        # from a distinct tenant needs its own pod; without autoscaling, all
        # concurrent streams contend on the same GPU. See the module README
        # "Autoscaling" section for load-test procedure.
        autoscaling = {
          min_replicas = 1
          max_replicas = 3
          # 3 min instead of module default 600s (10 min). SVD videos are
          # short (~24s on T4) and workloads tend to be bursty — a 10-min
          # idle GPU tail is ~$0.13 of wasted spend per event. Keep the
          # module default (600s) for services where cold-start dominates
          # and you'd rather pay for warm capacity than replay startup.
          scale_down_delay = 180
        }
      }
    }
  }
}
