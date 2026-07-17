output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.nim.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.nim.endpoint
}

output "cluster_security_group_id" {
  description = "Security group attached to the EKS cluster. Pass to eks-app for CodeBuild VPC placement."
  value       = aws_security_group.cluster.id
}

output "vpc_id" {
  description = "VPC ID — passed through for eks-app."
  value       = var.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs — passed through for eks-app CodeBuild vpc_config."
  value       = var.private_subnet_ids
}

output "node_role_name" {
  description = "EKS node IAM role name. Referenced in EC2NodeClass to assign the instance profile."
  value       = aws_iam_role.eks_node.name
}

output "nim_irsa_role_arn" {
  description = "IRSA role ARN for NIM pods. Annotated on the nim-sa service account in each deployment."
  value       = aws_iam_role.nim_irsa.arn
}

output "nim_irsa_role_name" {
  description = "IRSA role name for NIM pods. Used by root module to attach additional policies."
  value       = aws_iam_role.nim_irsa.name
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for the cluster. Used to create additional IRSA roles."
  value       = aws_iam_openid_connect_provider.eks.arn
}
