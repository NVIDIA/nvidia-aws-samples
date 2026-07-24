output "endpoint_names" {
  description = "Map of endpoint key to SageMaker endpoint name."
  value       = module.terraform-aws-nim.endpoint_names
}

output "sagemaker_endpoint_arns" {
  description = "Map of endpoint key to SageMaker endpoint ARN."
  value       = module.terraform-aws-nim.sagemaker_endpoint_arns
}

output "model_profile_cache_uris" {
  description = "S3 URIs for pre-cached NIM model profiles. Null for endpoints without enable_model_profile_cache."
  value       = module.terraform-aws-nim.model_profile_cache_uris
}

output "model_weights_s3_uris" {
  description = "Map of model slug to S3 URI where open-weight model files were downloaded."
  value       = module.terraform-aws-nim.model_weights_s3_uris
}

output "s3_model_assets_bucket" {
  description = "S3 bucket holding downloaded open-weight model files."
  value       = module.terraform-aws-nim.s3_model_assets_bucket
}

output "eks_cluster_names" {
  description = "Map of cluster key to EKS cluster name."
  value       = module.terraform-aws-nim.eks_cluster_names
}

output "eks_release_names" {
  description = "Map of deployment key to Helm release / deployment name."
  value       = module.terraform-aws-nim.eks_release_names
}

output "eks_namespaces" {
  description = "Map of deployment key to Kubernetes namespace."
  value       = module.terraform-aws-nim.eks_namespaces
}
