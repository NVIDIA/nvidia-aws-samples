# ---------------------------------------------------------------------------
# outputs.tf — Module root outputs
#
# Split into two sections:
#   1. Always-available — ECR, S3, IAM outputs exist regardless of platform config.
#   2. SageMaker outputs — maps keyed by sagemaker_endpoints key. Empty maps
#      when sagemaker_endpoints = {}.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Always-available outputs
# ---------------------------------------------------------------------------

output "ecr_repository_url" {
  description = "ECR repository base URL (no tag). Tags follow the pattern {image-name}-{version}-base and {image-name}-{version}-shim per unique source image."
  value       = aws_ecr_repository.nim.repository_url
}

output "ecr_base_image_uris" {
  description = "Map of endpoint key to ECR URI for the base NIM image ({image-name}-{version}-base tag). Used by EKS directly. Endpoints sharing the same source_image_uri point to the same URI. Only includes NIM endpoints (source_image_uri set). Empty when no NIM endpoints exist."
  value       = { for k, v in var.sagemaker_endpoints.nim : k => "${aws_ecr_repository.nim.repository_url}:${local.uri_base_tag[v.source_image_uri]}" }
}

output "ecr_shim_image_uris" {
  description = "Map of endpoint key to ECR URI for the SageMaker shim image ({image-name}-{version}-shim tag). This is the image SageMaker runs. Endpoints sharing the same source_image_uri point to the same URI. Only includes NIM endpoints (source_image_uri set). Empty when no NIM endpoints exist."
  value       = { for k, v in var.sagemaker_endpoints.nim : k => "${aws_ecr_repository.nim.repository_url}:${local.uri_shim_tag[v.source_image_uri]}" }
}

output "s3_build_bucket" {
  description = "S3 bucket for CodeBuild source (shim-source.zip)."
  value       = aws_s3_bucket.codebuild.bucket
}

output "s3_cache_bucket" {
  description = "S3 bucket for NGC model profile cache. Cache prefixes: nim-cache/{image-name}-{version}/{instance-type}/ per unique (image, instance) combo. Null when no endpoints have enable_model_profile_cache = true."
  value       = try(aws_s3_bucket.nim_cache[0].bucket, null)
}

output "s3_output_bucket" {
  description = "S3 bucket for SageMaker async inference response payloads."
  value       = aws_s3_bucket.sagemaker_output.bucket
}


output "sagemaker_execution_role_arn" {
  description = "ARN of the IAM role attached to SageMaker endpoints."
  value       = aws_iam_role.sagemaker_execution.arn
}

# ---------------------------------------------------------------------------
# SageMaker outputs — maps keyed by sagemaker_endpoints key
# Empty maps ({}) when sagemaker_endpoints = {}
# ---------------------------------------------------------------------------

output "endpoint_names" {
  description = "Map of endpoint key to SageMaker endpoint name. Keys are suffixed with -nim or -ow to distinguish deployment types when the same key appears in both maps."
  value = merge(
    { for k, v in aws_sagemaker_endpoint.nim : "${k}-nim" => v.name },
    { for k, v in aws_sagemaker_endpoint.open_weight : "${k}-ow" => v.name }
  )
}

output "sagemaker_endpoint_arns" {
  description = "Map of endpoint key to SageMaker endpoint ARN. Keys are suffixed with -nim or -ow. Empty when sagemaker_endpoints = {}."
  value = merge(
    { for k, v in aws_sagemaker_endpoint.nim : "${k}-nim" => v.arn },
    { for k, v in aws_sagemaker_endpoint.open_weight : "${k}-ow" => v.arn }
  )
}

output "async_output_prefixes" {
  description = "Map of endpoint key to S3 URI prefix where SageMaker writes InvokeEndpointAsync responses. Only includes async endpoints. Empty when no async endpoints exist."
  value = merge(
    {
      for k, v in var.sagemaker_endpoints.nim :
      k => "s3://${aws_s3_bucket.sagemaker_output.bucket}/${k}/${v.async_output_s3_prefix}"
      if v.endpoint_type == "async"
    },
    {
      for k, v in var.sagemaker_endpoints.open_weight :
      k => "s3://${aws_s3_bucket.sagemaker_output.bucket}/${k}/${v.async_output_s3_prefix}"
      if v.endpoint_type == "async"
    }
  )
}

# ---------------------------------------------------------------------------
# EKS outputs — maps keyed by eks_clusters / eks_deployments key
# Empty maps ({}) when eks_clusters / eks_deployments = {}
# ---------------------------------------------------------------------------

output "eks_cluster_names" {
  description = "Map of eks_clusters key to EKS cluster name. Empty when eks_clusters = {}."
  value       = { for k, v in module.eks_infra : k => v.cluster_name }
}

output "eks_cluster_endpoints" {
  description = "Map of eks_clusters key to EKS API server endpoint. Empty when eks_clusters = {}."
  value       = { for k, v in module.eks_infra : k => v.cluster_endpoint }
}

output "eks_nim_irsa_role_arns" {
  description = "Map of eks_clusters key to NIM IRSA role ARN. Annotated on nim-sa service accounts. Empty when eks_clusters = {}."
  value       = { for k, v in module.eks_infra : k => v.nim_irsa_role_arn }
}

output "eks_release_names" {
  description = "Map of eks_deployments key to Helm release name. Keys are suffixed with -nim or -ow to distinguish deployment types when the same key appears in both maps. Use with kubectl -n <namespace> to inspect deployments. Empty when eks_deployments = {}."
  value = merge(
    { for k, v in module.eks_app_nim : "${k}-nim" => v.release_name },
    { for k, v in module.eks_app_open_weight : "${k}-ow" => v.release_name }
  )
}

output "eks_namespaces" {
  description = "Map of eks_deployments key to Kubernetes namespace. Keys are suffixed with -nim or -ow to distinguish deployment types when the same key appears in both maps. Empty when eks_deployments = {}."
  value = merge(
    { for k, v in module.eks_app_nim : "${k}-nim" => v.namespace },
    { for k, v in module.eks_app_open_weight : "${k}-ow" => v.namespace }
  )
}

output "s3_model_assets_bucket" {
  description = "S3 bucket holding downloaded open-weight model files. Null when no open-weight endpoints exist."
  value       = try(aws_s3_bucket.model_assets[0].bucket, null)
}

output "model_weights_s3_uris" {
  description = "Map of endpoint key to S3 URI where open-weight model files were downloaded. Only includes open-weight endpoints (model_id set). Empty when no open-weight endpoints exist."
  value = {
    for k in keys(var.sagemaker_endpoints.open_weight) :
    k => "s3://${try(aws_s3_bucket.model_assets[0].bucket, "")}/${local.open_weight_s3_prefix[k]}"
  }
}

output "model_profile_cache_uris" {
  description = "Map of endpoint key to S3 URI for the pre-cached NGC model profile (nim-cache/{image-name}-{version}/{instance-type}/). Endpoints sharing the same source_image_uri and instance_type point to the same URI. Null per-entry when enable_model_profile_cache = false. Empty when sagemaker_endpoints = {}."
  value = {
    for k, v in var.sagemaker_endpoints.nim :
    k => v.enable_model_profile_cache ? "s3://${try(aws_s3_bucket.nim_cache[0].bucket, "")}/nim-cache/${local.uri_effective_canonical[v.source_image_uri]}/${replace(v.instance_type, "ml.", "")}" : null
  }
}
