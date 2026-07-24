variable "name_prefix" {
  type        = string
  description = "Resource name prefix. Derived from root module local.name_prefix + deployment key."
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

# ---------------------------------------------------------------------------
# EKS cluster — passed from modules/eks-infra outputs
# ---------------------------------------------------------------------------

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (output from modules/eks-infra)."
}

variable "cluster_security_group_id" {
  type        = string
  description = "EKS cluster security group ID (output from modules/eks-infra). Used for CodeBuild VPC placement."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (from eks_clusters config). Used for CodeBuild VPC placement."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (from eks_clusters config). Used for CodeBuild VPC placement."
}

variable "nim_irsa_role_arn" {
  type        = string
  description = "IRSA role ARN for NIM pods (output from modules/eks-infra). Annotated on the nim-sa service account."
}

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

variable "ecr_repository_url" {
  type        = string
  description = "ECR repository URL (without tag). Image is pulled from ECR by EKS nodes via node IAM role."
}

variable "ecr_image_tag" {
  type        = string
  default     = null
  description = "ECR image tag for the base NIM image (e.g. llama-3.1-8b-instruct-1.8.3-base). Null for open-weight deployments (uses DockerHub vLLM image directly)."
}

variable "model_id" {
  type        = string
  default     = null
  description = "Open weight model ID (e.g. meta-llama/Llama-3.1-8B-Instruct). When set, deploys via raw kubectl Deployment+Service instead of Helm. Null = NIM path."
}

variable "model_assets_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name for open weight downloads. Required when model_id is set."
}

variable "weights_s3_prefix" {
  type        = string
  default     = null
  description = "S3 key prefix for the model weights within model_assets_bucket (e.g. open-weights/huggingface/meta-llama-.../main)."
}

variable "extra_args_str" {
  type        = string
  default     = null
  description = "Rendered vLLM CLI flags string (e.g. '--tensor-parallel-size 4 --dtype bfloat16'). Appended to vllm serve command. Null or empty = no extra flags."
}

# ---------------------------------------------------------------------------
# NGC credentials
# ---------------------------------------------------------------------------

variable "ngc_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "Resolved NGC API key. Required at pod startup for NIM license validation even when image is from ECR."
}

# CodeBuild env-var pair for NGC credentials.
# ngc_cb_env_value carries either the resolved api_key (PLAINTEXT) or a Secrets Manager
# reference string like "<arn>:<json-key>::" (SECRETS_MANAGER). ngc_cb_env_type selects
# which CodeBuild env-var mode to use. Set together by the root module.
variable "ngc_cb_env_value" {
  type        = string
  default     = null
  sensitive   = true
  description = "CodeBuild env-var value for NGC_API_KEY — resolved API key when using PLAINTEXT mode, or Secrets Manager reference string when using SECRETS_MANAGER mode."
}

variable "ngc_cb_env_type" {
  type        = string
  default     = "PLAINTEXT"
  description = "CodeBuild env-var type for NGC_API_KEY. Either PLAINTEXT (dev, resolved value) or SECRETS_MANAGER (prod, ARN reference resolved by CodeBuild at build start)."
}

variable "ngc_secret_arn" {
  type        = string
  default     = null
  description = "NGC Secrets Manager ARN, when SECRETS_MANAGER mode is in use. Grants secretsmanager:GetSecretValue on this ARN to the deploy CodeBuild role. Null when using PLAINTEXT mode."
}

# ---------------------------------------------------------------------------
# Model profile cache
# ---------------------------------------------------------------------------

variable "enable_model_profile_cache" {
  type        = bool
  default     = false
  description = "When true, an init container syncs the pre-built model profile cache from S3 into the NIM pod at startup."
}

variable "cache_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name for the model profile cache. Required when enable_model_profile_cache = true."
}

variable "cache_prefix" {
  type        = string
  default     = null
  description = "S3 key prefix within cache_bucket (e.g. nim-cache/llama-3.1-8b-instruct-1.8.3/g6e.12xlarge)."
}

# ---------------------------------------------------------------------------
# Helm
# ---------------------------------------------------------------------------

variable "helm_chart_name" {
  type        = string
  default     = null
  description = "NGC Helm chart name. Derived from nim_type when null. Override for custom charts."
}

variable "helm_chart_repo_url" {
  type        = string
  default     = null
  description = "Base HTTPS URL for the NGC Helm chart repo. Derived from nim_type when null."
}

variable "helm_chart_version" {
  type        = string
  default     = null
  description = "Helm chart version to pull from NGC. Null = latest available."
}

variable "helm_chart_s3_uri" {
  type        = string
  default     = null
  description = "S3 URI of a custom Helm chart .tgz (e.g. s3://my-bucket/charts/my-nim-1.0.0.tgz). When set, skips NGC fetch entirely. Chart must be packaged with 'helm package' producing a .tgz."
}

variable "nim_type" {
  type        = string
  default     = "llm"
  description = "NIM category (used by the buildspec to select Helm values template + chart-specific quirks). One of: llm, vlm, embedding, reranking, speech, custom. See root-module variables.tf for the full per-type breakdown."
}

variable "protocol" {
  type        = string
  default     = "http"
  description = "Inference protocol: \"http\" (Helm deploy via the chart selected by nim_type) or \"grpc\" (raw kubectl Deployment+Service; no Helm)."
}

variable "port" {
  type        = number
  default     = 8000
  description = "Service port the NIM exposes for inference. Resolved by the root module from `port` (override) or sensible defaults per protocol + nim_type. The buildspec emits this as the Service `port` and `targetPort`."
}

variable "helm_values_override" {
  type        = string
  default     = null
  description = "Raw YAML string merged after the generated nim-values.yaml. Applied with a second -f flag so any key here wins over the generated defaults. Use to supply chart-specific fields the module doesn't generate (e.g. Riva model configs, custom resource limits)."
}

variable "gpu_count" {
  type        = number
  default     = 1
  description = "Number of GPUs to request per NIM pod replica. Increase for multi-GPU models (e.g. Mamba/SSM architectures that require more VRAM)."
}

variable "replicas" {
  type        = number
  default     = 1
  description = "Number of NIM pod replicas. When autoscaling is set, this is the initial replica count that KEDA takes over from."
}

variable "autoscaling" {
  type = object({
    min_replicas     = number
    max_replicas     = number
    metric           = string
    target_value     = number
    scale_down_delay = number
  })
  default     = null
  description = "Fully-resolved KEDA ScaledObject config (metric and target_value are non-null by the time this reaches eks-app — defaults were applied in the root module locals)."
}

variable "namespace" {
  type        = string
  default     = "nim"
  description = "Kubernetes namespace for the NIM deployment."
}

# ---------------------------------------------------------------------------
# Build control
# ---------------------------------------------------------------------------

variable "debug" {
  type        = bool
  default     = false
  description = "Enable verbose output in the deploy CodeBuild build."
}

variable "force_rebuild" {
  type        = bool
  default     = false
  description = "Force the deploy CodeBuild to re-run on next apply regardless of input changes."
}

variable "node_pool_name" {
  type        = string
  description = "Name of the GPU NodePool to wait for before deploying. Must match the NodePool created by eks-infra."
}

variable "load_balancer_internal" {
  type        = bool
  default     = false
  description = "When true, annotates the NIM Service as internal-facing (VPC only). When false, creates an internet-facing NLB (which must be paired with nlb_allowed_cidr_blocks — enforced by the root variable validation)."
}

variable "nlb_allowed_cidr_blocks" {
  type        = list(string)
  default     = null
  description = "CIDR blocks allowed to reach the inference NLB. Renders as loadBalancerSourceRanges on the Service; the LB controller writes these into the NLB security group ingress rules. Required when load_balancer_internal = false. Pass [\"0.0.0.0/0\"] to open explicitly to the internet."
}

variable "additional_scripts" {
  type        = list(string)
  default     = []
  description = "Resolved S3 URIs for additional scripts to run before the NIM/vLLM container starts. Scripts run in list order — as init containers for EKS."
}

variable "buildspec_s3_arn" {
  type        = string
  description = "S3 ARN of the deploy-nim buildspec (uploaded by the root module). Format: arn:aws:s3:::bucket/key. Sidesteps CodeBuild's 25,600-char inline buildspec limit."
}

variable "buildspec_s3_bucket" {
  type        = string
  description = "S3 bucket name that holds the buildspec object. Used for the CodeBuild service role's s3:GetObject grant."
}

variable "buildspec_s3_key" {
  type        = string
  description = "S3 key of the buildspec object within buildspec_s3_bucket. Used for the CodeBuild service role's s3:GetObject grant."
}
