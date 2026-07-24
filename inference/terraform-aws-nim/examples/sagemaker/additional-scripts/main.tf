module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = {
    secret_arn      = data.aws_secretsmanager_secret.ngc.arn
    secret_json_key = "access-key"
  }

  # Single-deployment example: one NIM on a single-GPU instance (`ml.g6e.xlarge`).
  # The `additional_scripts` mechanism is identical on the open-weight path — both
  # `sagemaker_endpoints.nim` and `sagemaker_endpoints.open_weight` go through
  # `shim/launch.sh`'s ADDITIONAL_SCRIPTS loop. See `examples/sagemaker/open-weight/`
  # for the open-weight pattern; the `additional_scripts` block here works identically
  # when added to an open_weight entry.
  sagemaker_endpoints = {
    nim = {
      llama-nemotron-nano-8b = {
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        instance_type              = "ml.g6e.xlarge"
        enable_model_profile_cache = true

        # Scripts run in order inside the container before Caddy and NIM start.
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
