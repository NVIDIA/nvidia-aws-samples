output "eks_cluster_names" {
  description = "Map of cluster key to EKS cluster name."
  value       = module.terraform-aws-nim.eks_cluster_names
}

output "eks_release_names" {
  description = "Map of deployment key to release/Deployment name."
  value       = module.terraform-aws-nim.eks_release_names
}

output "eks_namespaces" {
  description = "Map of deployment key to Kubernetes namespace."
  value       = module.terraform-aws-nim.eks_namespaces
}
