# Zips ./shim/ and uploads to S3 as the CodeBuild source.
# output_md5 is the change-detection signal in codebuild.tf —
# when any file in shim/ changes, the build triggers re-run.

data "archive_file" "shim_source" {
  type        = "zip"
  source_dir  = "${path.module}/shim"
  output_path = "${path.module}/tmp/shim-source.zip"
}

resource "aws_s3_object" "shim_source" {
  count = length(var.sagemaker_endpoints) > 0 ? 1 : 0

  region = var.region
  bucket = aws_s3_bucket.codebuild.id
  key    = "codebuild-source/shim-source.zip"
  source = data.archive_file.shim_source.output_path
  etag   = filemd5(data.archive_file.shim_source.output_path)
}

# Upload local additional_scripts files to S3.
# Keyed by local file path — deduplicated across all endpoint types automatically.
# s3:// sources are referenced directly and do not need uploading.
locals {
  all_local_additional_scripts = toset(flatten([
    [for k, v in var.sagemaker_endpoints.nim : [for s in v.additional_scripts : s.source if !startswith(s.source, "s3://")]],
    [for k, v in var.sagemaker_endpoints.open_weight : [for s in v.additional_scripts : s.source if !startswith(s.source, "s3://")]],
    [for k, v in var.eks_deployments.nim : [for s in v.additional_scripts : s.source if !startswith(s.source, "s3://")]],
    [for k, v in var.eks_deployments.open_weight : [for s in v.additional_scripts : s.source if !startswith(s.source, "s3://")]],
  ]))
}

resource "aws_s3_object" "additional_scripts" {
  for_each = local.all_local_additional_scripts

  region = var.region
  bucket = aws_s3_bucket.codebuild.id
  key    = "additional-scripts/${filemd5(each.value)}/${basename(each.value)}"
  source = each.value
  etag   = filemd5(each.value)
}

# ---------------------------------------------------------------------------
# CodeBuild buildspecs — hosted in S3, not inlined into the CodeBuild
# project resource.
#
# The AWS CodeBuild project's `source.buildspec` field has a 25,600-character
# limit when the buildspec is provided inline. deploy-nim.yml exceeds that
# once rationale comments and multi-path emission logic are included, so we
# upload the buildspec YAML to S3 and reference it by ARN.
#
# CodeBuild reads the buildspec from S3 at build-time — the identical shell
# script runs regardless of storage location. Uploading here (root module)
# rather than per-module-instance de-duplicates: all cluster-setup CodeBuild
# projects share one buildspec object, all deploy CodeBuild projects share
# another. Change to either file → new etag → new S3 PutObject → change to
# each module's terraform_data.*_trigger.input.buildspec_hash → re-fired
# CodeBuild action on next apply.
# ---------------------------------------------------------------------------

resource "aws_s3_object" "cluster_setup_buildspec" {
  count = length(var.eks_clusters) > 0 ? 1 : 0

  region       = var.region
  bucket       = aws_s3_bucket.codebuild.id
  key          = "buildspecs/cluster-setup.yml"
  source       = "${path.module}/modules/eks-infra/buildspecs/cluster-setup.yml"
  etag         = filemd5("${path.module}/modules/eks-infra/buildspecs/cluster-setup.yml")
  content_type = "text/yaml"
}

resource "aws_s3_object" "deploy_nim_buildspec" {
  count = length(var.eks_deployments.nim) + length(var.eks_deployments.open_weight) > 0 ? 1 : 0

  region       = var.region
  bucket       = aws_s3_bucket.codebuild.id
  key          = "buildspecs/deploy-nim.yml"
  source       = "${path.module}/modules/eks-app/buildspecs/deploy-nim.yml"
  etag         = filemd5("${path.module}/modules/eks-app/buildspecs/deploy-nim.yml")
  content_type = "text/yaml"
}
