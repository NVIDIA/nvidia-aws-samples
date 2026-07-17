output "endpoint_names" {
  description = "Map of endpoint key to SageMaker endpoint name."
  value       = module.terraform-aws-nim.endpoint_names
}

output "sagemaker_endpoint_arns" {
  description = "Map of endpoint key to SageMaker endpoint ARN."
  value       = module.terraform-aws-nim.sagemaker_endpoint_arns
}

output "model_weights_s3_uris" {
  description = "Map of endpoint key to S3 URI where model weights were downloaded."
  value       = module.terraform-aws-nim.model_weights_s3_uris
}

output "s3_model_assets_bucket" {
  description = "S3 bucket holding downloaded model weights."
  value       = module.terraform-aws-nim.s3_model_assets_bucket
}
