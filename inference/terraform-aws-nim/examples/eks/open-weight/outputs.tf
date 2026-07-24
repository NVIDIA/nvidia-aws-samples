output "eks_cluster_names" {
  description = "Map of cluster key to EKS cluster name."
  value       = module.terraform-aws-nim.eks_cluster_names
}

output "eks_release_names" {
  description = "Map of deployment key to deployment/release name."
  value       = module.terraform-aws-nim.eks_release_names
}

output "eks_namespaces" {
  description = "Map of deployment key to Kubernetes namespace."
  value       = module.terraform-aws-nim.eks_namespaces
}

output "model_weights_s3_uris" {
  description = "Map of model slug to S3 URI where weights were downloaded."
  value       = module.terraform-aws-nim.model_weights_s3_uris
}

output "s3_model_assets_bucket" {
  description = "S3 bucket holding downloaded model weights."
  value       = module.terraform-aws-nim.s3_model_assets_bucket
}
