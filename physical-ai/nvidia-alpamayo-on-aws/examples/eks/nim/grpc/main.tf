# ─────────────────────────────────────────────────────────────────────────────
# nvidia-alpamayo-on-aws — Alpamayo 1.5 on EKS over gRPC
#
# Deploys the NVIDIA Alpamayo 1.5 NIM to an EKS Auto Mode cluster serving its
# gRPC inference API on port 50051. EKS-only — SageMaker's invocation API is
# HTTP/1.1 and does not support gRPC, so there is no SageMaker counterpart.
#
# Same container, different deploy path than eks/http:
#   Alpamayo is ONE container that serves BOTH HTTP (8000) and gRPC (50051).
#   eks/http deploys it via the nim-wfm Helm chart (with the chart's 150Gi
#   persistent model cache). This example uses the module's raw-kubectl path
#   (protocol = "grpc" bypasses Helm), so it runs the same container but WITHOUT
#   the chart's persistent cache — functional, but cold starts re-pull the model
#   each restart. Use this when you specifically need gRPC; prefer eks/http's
#   chart deploy for production caching.
# ─────────────────────────────────────────────────────────────────────────────

module "terraform-aws-nim" {
  source = "../../../../../../inference/terraform-aws-nim"

  project_prefix = "alpamayo"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

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
      # L40S (g6e) — see eks/http/main.tf for the full instance-selection rationale.
      instance_type           = "g6e.xlarge"
      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id
      enable_autoscaling      = true
    }
  }

  # gRPC NIM example: Alpamayo 1.5 over gRPC (port 50051).
  #
  # Why nim_type = "custom" + protocol = "grpc":
  #   The gRPC path deploys via raw kubectl (Deployment + Service), so no Helm
  #   chart is fetched — nim_type = "custom" is the correct categorization for a
  #   NIM the module has no built-in family for.
  #
  # Why port = 50051:
  #   Alpamayo serves gRPC on 50051. The module's grpc default is 8001 (the
  #   Maxine media-NIM convention), so it MUST be overridden here.
  eks_deployments = {
    nim = {
      alpamayo = {
        cluster_key      = "alpamayo"
        source_image_uri = "nvcr.io/nim/nvidia/alpamayo-1-5-10b:1.0.0"
        nim_type         = "custom"
        protocol         = "grpc"
        port             = 50051

        # Restrict the internet-facing NLB to the deployer's IP. Required by module
        # validation when load_balancer_internal = false.
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        # nim_type = "custom" → KEDA scales on DCGM_FI_DEV_GPU_UTIL (auto-derived).
        autoscaling = {
          min_replicas = 1
          max_replicas = 3
        }
      }
    }
  }
}
