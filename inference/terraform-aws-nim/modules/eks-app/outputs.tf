output "release_name" {
  description = "Helm release name for the NIM deployment."
  value       = local.release_name
}

output "namespace" {
  description = "Kubernetes namespace the NIM deployment is installed into."
  value       = var.namespace
}
