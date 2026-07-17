module "terraform-aws-nim" {
  source = "../../.."

  project_prefix = "nim-testing"
  environment    = "dev"
  region         = var.region != null ? var.region : data.aws_region.current.region

  ngc_credentials = {
    secret_arn = data.aws_secretsmanager_secret.ngc.arn
  }

  sagemaker_endpoints = {
    nim = {
      llama-nemotron-nano-8b = {
        source_image_uri           = "nvcr.io/nim/nvidia/llama-3.1-nemotron-nano-8b-v1:latest"
        instance_type              = "ml.g6e.xlarge"
        enable_model_profile_cache = true
      }
    }
  }
}
