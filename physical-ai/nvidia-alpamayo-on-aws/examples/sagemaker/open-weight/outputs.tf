output "endpoint_names" {
  description = "Map of endpoint key to SageMaker endpoint name."
  value       = module.terraform-aws-nim.endpoint_names
}

output "sagemaker_endpoint_arns" {
  description = "Map of endpoint key to SageMaker endpoint ARN."
  value       = module.terraform-aws-nim.sagemaker_endpoint_arns
}

output "async_output_prefixes" {
  description = "Map of endpoint key to S3 output prefix (async endpoints only)."
  value       = module.terraform-aws-nim.async_output_prefixes
}
