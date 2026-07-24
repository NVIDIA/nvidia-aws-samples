# ---------------------------------------------------------------------------
# AWS identity
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Credentials — no Terraform-time secret resolution
#
# When ngc_credentials.secret_arn / hf_credentials.secret_arn is set, the module
# forwards only the ARN (+ optional JSON key name) to consumers:
#   - CodeBuild env vars use type = SECRETS_MANAGER; the value is fetched at
#     build start via IAM.
#   - SageMaker Model container env vars carry NGC_SECRET_ARN + NGC_SECRET_JSON_KEY;
#     shim/launch.sh fetches the value at container startup via IAM (see
#     iam.tf SageMakerSecretsManagerRead statement).
#
# No data.aws_secretsmanager_secret_version blocks: pulling secret_string here
# would put the raw value in Terraform state AND surface it via
# sagemaker:DescribeModel (Model container env vars are returned plaintext).
