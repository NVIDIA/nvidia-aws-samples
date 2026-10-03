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

output "model_profile_cache_uris" {
  description = "S3 URIs for pre-cached NIM manifest profiles."
  value       = module.terraform-aws-nim.model_profile_cache_uris
}
