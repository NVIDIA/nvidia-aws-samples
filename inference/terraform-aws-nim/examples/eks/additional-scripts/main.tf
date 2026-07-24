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
      vpc_id                  = aws_vpc.main.id
      private_subnet_ids      = aws_subnet.private[*].id
      public_subnet_ids       = aws_subnet.public[*].id
      instance_type           = "g6e.xlarge"
      endpoint_public_access  = true
      endpoint_private_access = true
      public_access_cidrs     = ["${chomp(data.http.my_ip.response_body)}/32"]
      allowed_cidr_blocks     = ["${chomp(data.http.my_ip.response_body)}/32"]
      internet_gateway_id     = aws_internet_gateway.main.id
    }
  }

  # Single-deployment example: one NIM on a single-GPU cluster (`g6e.xlarge`).
  # The `additional_scripts` mechanism works identically for the open-weight path —
  # see `examples/eks/open-weight/` for that pattern. To run NIM + open-weight on the
  # same cluster, bump `instance_type` to a multi-GPU size (e.g. `g6e.12xlarge`) so
  # the two deployments don't contend for a single GPU.
  eks_deployments = {
    nim = {
      llama-nemotron-nano-8b = {
        cluster_key        = "llama-nemotron-nano-8b"
        source_image_uri   = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        helm_chart_version = "2.0.3"

        # Restrict the internet-facing NLB to the deployer's IP (module validation
        # requires this when load_balancer_internal = false).
        nlb_allowed_cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]

        # Scripts run in order as init containers before the NIM pod starts.
        # Local files are uploaded to S3 automatically — no manual zip or upload needed.
        # Place scripts in the order you want them to execute.
        additional_scripts = [
          { source = "${path.module}/../../scripts/local-test.sh" }, # local file — uploaded to S3 automatically
          { source = var.remote_script_s3_uri },                     # existing S3 object — supply via terraform.tfvars or -var
        ]
      }
    }
  }
}
