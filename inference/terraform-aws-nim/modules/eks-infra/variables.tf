variable "name_prefix" {
  type        = string
  description = "Resource name prefix. Derived from root module local.name_prefix + cluster key."
}

variable "region" {
  type        = string
  description = "AWS region."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}

variable "vpc_id" {
  type        = string
  description = "VPC ID to deploy the EKS cluster into."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EKS nodes and CodeBuild. Must have outbound internet access via NAT gateway."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs. Tagged kubernetes.io/role/elb=1 for load balancer placement."
}

variable "instance_type" {
  type        = string
  description = "EC2 GPU instance type for NIM nodes (e.g. g6e.12xlarge). No ml. prefix."
}

variable "kubernetes_version" {
  type        = string
  default     = "1.35"
  description = "Kubernetes version for the EKS cluster. Default 1.35 (latest standard support as of this module version). Check https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html for current versions."
}

variable "endpoint_public_access" {
  type        = bool
  default     = true
  description = "Enable public EKS API server endpoint."
}

variable "endpoint_private_access" {
  type        = bool
  default     = true
  description = "Enable private EKS API server endpoint. Must be true — CodeBuild is VPC-placed."

  # Enforce the invariant at plan time: the cluster-setup and deploy CodeBuild
  # projects both run inside the cluster VPC (no NAT to a public EKS endpoint)
  # and would fail with a hard-to-diagnose connectivity error at build time.
  validation {
    condition     = var.endpoint_private_access == true
    error_message = "endpoint_private_access must be true — the module's CodeBuild projects run inside the cluster VPC and require the private API server endpoint to reach the control plane."
  }
}

variable "public_access_cidrs" {
  type        = list(string)
  default     = null
  description = "CIDR blocks allowed to reach the public API endpoint. Null = all. Only used when endpoint_public_access = true."
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  default     = null
  description = "Additional CIDR blocks (e.g. developer VPN, office) granted port 443 ingress on the cluster security group."
}

variable "cluster_log_types" {
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  description = "EKS control plane log types to enable. Sent to CloudWatch Logs."
}

variable "internet_gateway_id" {
  type        = string
  default     = null
  description = "IGW ID from the consumer VPC. Creates a destroy-time fence: the EKS cluster is always destroyed before the IGW, preventing ENI/NLB cleanup failures from blocking VPC teardown."
}

variable "eks_access_entries" {
  type = map(object({
    principal_arn = string
    type          = optional(string, "STANDARD")
    policy_associations = optional(list(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), [])
  }))
  default     = {}
  description = "Additional EKS access entries (IAM roles/users that need kubectl access). The cluster creator and CodeBuild roles get admin access automatically."
}

variable "cache_bucket_arn" {
  type        = string
  default     = null
  description = "ARN of the shared NIM model profile cache S3 bucket. Grants NIM pod IRSA read access."
}

variable "enable_cache_iam" {
  type        = bool
  default     = false
  description = "Create the NIM IRSA S3 policy that grants read access to the cache bucket. Must be set from a plan-time-known value (not a computed resource attribute) to avoid count dependency errors."
}


variable "enable_autoscaling" {
  type        = bool
  default     = false
  description = "Install KEDA + kube-prometheus-stack + DCGM exporter as part of cluster-setup. Required before any deployment on this cluster can use ScaledObject-based autoscaling."
}

variable "buildspec_s3_arn" {
  type        = string
  description = "S3 ARN of the cluster-setup buildspec (uploaded by the root module). Format: arn:aws:s3:::bucket/key. Sidesteps CodeBuild's 25,600-char inline buildspec limit."
}

variable "buildspec_s3_bucket" {
  type        = string
  description = "S3 bucket name that holds the buildspec object. Used for the CodeBuild service role's s3:GetObject grant."
}

variable "buildspec_s3_key" {
  type        = string
  description = "S3 key of the buildspec object within buildspec_s3_bucket. Used for the CodeBuild service role's s3:GetObject grant."
}

variable "debug" {
  type        = bool
  default     = false
  description = "Enable verbose (set -x) output in the cluster-setup CodeBuild build."
}

variable "force_rebuild" {
  type        = bool
  default     = false
  description = "Force cluster-setup CodeBuild to re-run on next apply regardless of input changes."
}
