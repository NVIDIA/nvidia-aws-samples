# ─────────────────────────────────────────────────────────────────────────────
# nvidia-alpamayo-on-aws — Alpamayo 1.5 on EKS over HTTP
#
# Deploys the NVIDIA Alpamayo 1.5 NIM (10B autonomous-driving VLM on the
# Cosmos-Reason2 backbone) to an EKS Auto Mode cluster, serving its HTTP
# inference API (POST /v1/infer on port 8000) via the nim-wfm Helm chart.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../../inference/terraform-aws-nim"

  project_prefix = "alpamayo"
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
    alpamayo = {
      vpc_id             = aws_vpc.main.id
      private_subnet_ids = aws_subnet.private[*].id
      public_subnet_ids  = aws_subnet.public[*].id

      # Alpamayo 1.5 (10B VLM) runs on any GPU with sufficient VRAM. On AWS,
      # L40S (g6e) is the right-sized single-GPU option:
      #   * 48 GB VRAM — comfortable for the 10B model
      #   * Supports ALL Alpamayo precisions (bf16 / fp8 / w4a16); the NIM
      #     auto-selects a compatible profile for the visible GPU
      #   * RTX 4090 (the other tested GPU) isn't offered on AWS; H100/H200
      #     only come in 8-GPU p5 instances — no right-sized single-GPU option
      # g6e.xlarge = 1× L40S, 4 vCPU, 32 GB RAM (single-deployment default).
      instance_type = "g6e.xlarge"

      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id

      # Installs KEDA + kube-prometheus-stack + DCGM exporter cluster-wide so the
      # deployment below can opt into pod autoscaling. Adds ~5 min to first apply.
      enable_autoscaling = true
    }
  }

  # HTTP NIM example: Alpamayo 1.5 over HTTP (`POST /v1/infer`, port 8000).
  #
  # Why nim_type = "custom" (not "vlm"):
  #   Alpamayo publishes the `nim-wfm` (NIM Workflow Manager) Helm chart on NGC —
  #   NOT the generic `nim-vlm` chart the module derives for nim_type = "vlm".
  #   Same NGC repo (helm.ngc.nvidia.com/nim/charts), different chart. So we set
  #   nim_type = "custom" and point helm_chart_name/repo/version at nim-wfm
  #   explicitly, and supply the chart values via helm_values_override (custom
  #   generates no base values).
  #
  # Autoscaling: nim_type = "custom" → KEDA scales on DCGM_FI_DEV_GPU_UTIL
  #   (auto-derived). Safer here than the llm/vlm gpu_cache_usage_perc metric
  #   since the WFM chart's request-load telemetry isn't confirmed.
  eks_deployments = {
    nim = {
      alpamayo = {
        cluster_key = "alpamayo"

        # NGC catalog slug: alpamayo-1-5-10b. The nim-wfm chart and docs alias
        # the image as `alpamayo1.5` (see helm_values_override below).
        source_image_uri = "nvcr.io/nim/nvidia/alpamayo-1-5-10b:1.0.0"

        nim_type            = "custom"
        protocol            = "http"
        port                = 8000
        helm_chart_name     = "nim-wfm"
        helm_chart_repo_url = "https://helm.ngc.nvidia.com/nim/charts"

        # nim-wfm chart version (NGC has no chart index, so it must be pinned).
        helm_chart_version = "1.1.1"

        # custom nim_type generates no base values — supply the nim-wfm chart
        # values here (mirrors the Alpamayo quickstart's custom-values.yaml).
        helm_values_override = <<-YAML
          image:
            repository: nvcr.io/nim/nvidia/alpamayo1.5
            tag: "1.0.0"
          model:
            name: nvidia/alpamayo1.5
          resources:
            limits:
              nvidia.com/gpu: 1
          # The chart provisions its own 150Gi persistent model cache.
          persistence:
            enabled: true
            size: 150Gi
          # Optional env. Precision auto-selects per GPU when NIM_PRECISION is
          # omitted (L40S supports bf16 / fp8 / w4a16). Uncomment to pin one:
          # env:
          #   - name: NIM_PRECISION
          #     value: "fp8"
          #   - name: NIM_ALPAMAYO_TRAJ_SAMPLES
          #     value: "1"
        YAML

        # Restrict the internet-facing NLB to the deployer's IP (module validation
        # requires this when load_balancer_internal = false). Use ["0.0.0.0/0"] to
        # opt into a fully open endpoint.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        autoscaling = {
          min_replicas = 1
          max_replicas = 3
        }
      }
    }
  }
}
