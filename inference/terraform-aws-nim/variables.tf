# ---------------------------------------------------------------------------
# Shared — required for all platforms
# ---------------------------------------------------------------------------

variable "project_prefix" {
  type        = string
  description = "Prefix for all resource names. Should identify the deployment (e.g. \"nim-alpamayo\", \"nim-llama\"). Combined with environment to form local.name_prefix."

  validation {
    condition     = length(var.project_prefix) > 1 && length(var.project_prefix) <= 28
    error_message = "The defined 'project_prefix' has too many characters. This can cause deployment failures for AWS resources with smaller character limits. Please reduce the character count and try again."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment label (e.g. dev, staging, prod). Combined with project_prefix to form local.name_prefix."

  validation {
    condition     = length(var.environment) > 1 && length(var.environment) <= 8
    error_message = "The defined 'environment' has too many characters. This can cause deployment failures for AWS resources with smaller character limits. Please reduce the character count and try again."
  }
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to deploy into."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources. Merged with a resource-specific Name tag per resource."
  default = {
    IaC            = "Terraform"
    ModuleBy       = "NVIDIA"
    RootModuleName = "-"
    ModuleName     = "terraform-aws-nim"
    ModuleSource   = "https://github.com/NVIDIA/nvidia-aws-samples/tree/main/inference/terraform-aws-nim"
  }
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch log retention in days for SageMaker endpoint log groups. Set to 0 for never expire."
}

# ---------------------------------------------------------------------------
# Credentials
#
# NGC credentials are shared across all endpoints — a single NGC API key
# authenticates both image pulls (base-sync) and download-to-cache (profile caching).
# ---------------------------------------------------------------------------

variable "ngc_credentials" {
  type = object({
    api_key         = optional(string, null)
    secret_arn      = optional(string, null)
    secret_json_key = optional(string, null)
  })
  sensitive   = true
  default     = null
  description = <<-EOD
    NGC API key for NIM license validation (checked at every container startup) and
    image pull when any endpoint's source_image_uri is an nvcr.io URI.

    Provide exactly one of:
      api_key    — raw NGC API key string. Stored in Terraform state — only use for
                   development. Use secret_arn for production.
      secret_arn — ARN of an existing AWS Secrets Manager secret. When set, the module
                   references the secret directly in CodeBuild environment variables via
                   the SECRETS_MANAGER env-var type — the raw value never enters
                   Terraform state or CodeBuild project config. CodeBuild fetches the
                   value at build start via IAM (secretsmanager:GetSecretValue on the
                   specific ARN). Two secret formats supported:

                   Option A — Plaintext secret (recommended, default):
                     In the Secrets Manager console, choose "Plaintext" and paste the
                     raw NGC API key. Leave secret_json_key = null.

                   Option B — Key/value secret:
                     In the Secrets Manager console, choose "Key/value" and add an
                     entry with a specific key name. Set secret_json_key to that key
                     name (e.g. "access-key" or "ngc_api_key"). The module references
                     "<arn>:<secret_json_key>::" so CodeBuild extracts the right value.

    secret_json_key — Optional JSON key name for Option B key/value secrets. Ignored when
                      api_key is set or when the secret is plaintext.

    Providing both api_key and secret_arn is a validation error. Null is acceptable
    when all endpoints use ECR source images and license validation is not required.
  EOD

  validation {
    condition = var.ngc_credentials == null || !(
      var.ngc_credentials.api_key != null && var.ngc_credentials.secret_arn != null
    )
    error_message = "ngc_credentials: set api_key OR secret_arn, not both."
  }
}

variable "hf_credentials" {
  type = object({
    token           = optional(string, null)
    secret_arn      = optional(string, null)
    secret_json_key = optional(string, null)
  })
  sensitive   = true
  default     = null
  description = <<-EOD
    HuggingFace token for gated model weight download. Required when any
    sagemaker_endpoints entry has model_source = "huggingface" and the model is gated
    (e.g. Meta Llama, Mistral). Public models (e.g. Qwen, Phi) do not require a token.

    Provide exactly one of:
      token      — plaintext HuggingFace token. Stored in Terraform state — use only
                   for development. Use secret_arn for production.
      secret_arn — ARN of an existing AWS Secrets Manager secret containing the token.

    Null is acceptable when all open weight endpoints use public HuggingFace models or
    model_source = "ngc".
  EOD

  validation {
    condition = var.hf_credentials == null || !(
      var.hf_credentials.token != null && var.hf_credentials.secret_arn != null
    )
    error_message = "hf_credentials: set token OR secret_arn, not both."
  }
}

# ---------------------------------------------------------------------------
# Platform: SageMaker
# ---------------------------------------------------------------------------

variable "sagemaker_endpoints" {
  # Inner maps default to {} not null.
  # An empty map means "nothing configured" and for_each/length handle it
  # naturally — nothing iterates, length = 0. No null guards needed anywhere.
  type = object({
    nim = optional(map(object({
      source_image_uri           = string
      instance_type              = string
      endpoint_type              = optional(string, "realtime")
      sync_to_ecr                = optional(bool, true)
      container_startup_timeout  = optional(number, 600)
      enable_model_profile_cache = optional(bool, false)
      model_profile              = optional(string, null)
      inference_ami_version      = optional(string, null)
      endpoint_name              = optional(string, null)
      async_output_s3_prefix     = optional(string, "async-output/")
      ml_reservation_arn         = optional(string, null)
      debug                      = optional(bool, false)
      force_rebuild              = optional(bool, false)
      additional_scripts         = optional(list(object({ source = string })), [])
      shim_config = optional(object({
        nim_cmd            = optional(string, null)
        nim_entrypoint     = optional(string, null)
        caddy_backend_port = optional(number, null)
        cuda_driver_label  = optional(string, null)
      }), {})
    })), {})
    open_weight = optional(map(object({
      model_id                  = string
      model_source              = string
      instance_type             = string
      model_revision            = optional(string, "main")
      framework                 = optional(string, "vllm")
      extra_args                = optional(map(string), {})
      enable_vllm_recipe        = optional(bool, false)
      vllm_precision            = optional(string, "default")
      endpoint_type             = optional(string, "realtime")
      container_startup_timeout = optional(number, 600)
      inference_ami_version     = optional(string, null)
      endpoint_name             = optional(string, null)
      async_output_s3_prefix    = optional(string, "async-output/")
      ml_reservation_arn        = optional(string, null)
      debug                     = optional(bool, false)
      force_rebuild             = optional(bool, false)
      additional_scripts        = optional(list(object({ source = string })), [])
    })), {})
  })
  # Outer object defaults to {} so .nim and .open_weight are always accessible.
  # Callers who don't use SageMaker at all simply omit this variable entirely.
  default     = {}
  description = <<-EOD
    SageMaker inference endpoints. Two sub-maps: nim (NGC container) and open_weight (HuggingFace/NGC weights + vLLM).

    nim entries: use source_image_uri (NGC or ECR container image). Helm is not used for SageMaker.
    open_weight entries: use model_id + model_source. Module downloads weights to S3 and runs vLLM.

    Key naming: letters, numbers, hyphens only. Periods and underscores break SageMaker endpoint name validation.

    Example:
      sagemaker_endpoints = {
        nim = {
          nemotron-9b = {
            source_image_uri           = "nvcr.io/nim/nvidia/nvidia-nemotron-nano-9b-v2:latest"
            instance_type              = "ml.g6e.12xlarge"
            enable_model_profile_cache = true
          }
        }
        open_weight = {
          nemotron-9b = {
            model_id      = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"
            model_source  = "huggingface"
            instance_type = "ml.g6e.12xlarge"
          }
        }
      }

    nim per-endpoint fields:
      source_image_uri           — NIM container image URI (required). Two forms:
                                     NGC: "nvcr.io/nim/<org>/<model>:<tag>"
                                           Requires ngc_credentials to be set.
                                     ECR: "<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>"
                                           Authenticated via IAM — no extra credentials.

      instance_type              — SageMaker instance type (required). e.g. "ml.g6e.12xlarge".

                                   Validated instance types for standard NGC NIMs:
                                     ml.g6e.12xlarge — 4x L40S (48 GB VRAM)  SM89  VALIDATED
                                     ml.g6.12xlarge  — 4x L4   (24 GB VRAM)  SM89  at VRAM minimum
                                     ml.p5.48xlarge  — 8x H100 (80 GB VRAM)  SM90  confirmed
                                     ml.g5.*         — A10G/SM86 — avoid; vllm:latest requires CUDA driver >= 580.x, g5 AMIs ship older drivers

      endpoint_type              — SageMaker endpoint invocation mode. Default "realtime".
                                     "realtime" — synchronous inference (POST /invocations,
                                                  response returned inline). Request body limit
                                                  6 MB. Best for standard NGC NIMs (Llama, etc.)
                                                  with small-to-moderate payloads.
                                     "async"    — asynchronous inference. Payload uploaded to S3,
                                                  response written to async_output_s3_prefix.
                                                  Required for large payloads (> 6 MB) — e.g.
                                                  Alpamayo (16 base64-encoded camera frames, ~50 MB).
                                                  Adds async_output_s3_prefix to the config.

      sync_to_ecr                — Controls whether the source image is copied into the module's
                                   ECR repo before the shim is built. Default true.
                                   The shim image always lives in your ECR regardless of this setting.

                                   Four cases:
                                     nvcr.io URI  + sync_to_ecr = true  (default) — base-sync pulls
                                       from NGC -> your ECR. Shim + cache use your ECR.
                                     ECR URI      + sync_to_ecr = true  — base-sync pulls from their
                                       ECR -> your ECR. Shim + cache use your ECR.
                                     ECR URI      + sync_to_ecr = false — base-sync skipped. Shim
                                       builds FROM source URI directly. If enable_model_profile_cache
                                       = true, cache also runs FROM source URI. Their account must
                                       grant your SageMaker execution role pull access.
                                     nvcr.io URI  + sync_to_ecr = false — INVALID. nvcr.io requires
                                       NGC credentials not available at SageMaker/EKS runtime.

      container_startup_timeout  — Health-check timeout in seconds. Default 600 (10 min)
                                   suits a warm S3 cache. Increase to 3600 for cold start.

      enable_model_profile_cache — Pre-deployment cache the best NGC model profile for this
                                   endpoint in S3. Default false. Reduces cold start from
                                   ~5-10 min (NGC download) to ~2-5 min (S3 sync).
                                   Cache prefix: s3://<cache_bucket>/nim-cache/<key>/

      model_profile              — NGC profile name prefix override. null (default) =
                                   auto-select best profile for the instance type. Non-null
                                   = prefix-match (e.g. "vllm-bf16-tp1"). The full name
                                   with workspace hash is resolved automatically.
                                   Requires enable_model_profile_cache = true.

      inference_ami_version      — Explicit SageMaker InferenceAmiVersion override. null
                                   (default) lets SageMaker pick the AMI.

      endpoint_name              — Custom endpoint name override. null (default) auto-generates
                                   as "$${project_prefix}-$${environment}-$${key}".

      async_output_s3_prefix     — S3 key prefix for async inference response payloads,
                                   relative to s3://<output_bucket>/<key>/. Default: "async-output/".

      ml_reservation_arn         — ARN of a SageMaker Flexible Training Plan reservation.
                                   STUB — hashicorp/aws provider does not expose this attribute yet.
                                   See DEVELOPER_REFERENCE.md.

      debug                      — Enable verbose logging for this endpoint's CodeBuild builds
                                   only (base-sync, shim, model-profile-cache). Equivalent to
                                   the module-level debug variable but scoped to this endpoint.

      force_rebuild              — Force this endpoint's CodeBuild builds to re-run on the next
                                   apply regardless of whether inputs changed. Only retriggers
                                   builds for this endpoint's source URI (and instance type for
                                   cache). Other endpoints are unaffected.

      shim_config                — Per-endpoint overrides for the SageMaker shim image (Caddy
                                   proxy + NIM launcher). Mirrors var.shim_config but scoped to
                                   this endpoint only — same hierarchy as debug / force_rebuild
                                   vs. var.shim_config; null fields fall back to var.shim_config.
                                   Omit entirely for standard NGC NIMs.

                                   nim_cmd            — Shell command to start the NIM.
                                   nim_entrypoint     — NIM entrypoint script path in base image.
                                   caddy_backend_port — Port Caddy routes to. Null = auto-detected
                                                        from NIM_HTTP_API_PORT at container startup
                                                        (standard NIMs expose 8000). Only set for
                                                        custom NIMs on a different port (e.g. 8001).
                                   cuda_driver_label  — CUDA version for SageMaker AMI selection.

                                   Example (custom NIM):
                                     shim_config = {
                                       nim_cmd            = "python /workspace/server.py"
                                       caddy_backend_port = 8001
                                     }

    open_weight per-endpoint fields:
      model_id               — Open weight model identifier (required). When set the module runs a
                               weight-fetch CodeBuild job (downloads weights to S3), builds a vLLM
                               shim image, and syncs weights from S3 at container startup.
                               Format depends on model_source:
                                 "huggingface" — HuggingFace repo ID,
                                                 e.g. "meta-llama/Llama-3.1-8B-Instruct"
                                                 NOTE: gated models (e.g. Meta Llama)
                                                 require the HF account to accept terms
                                                 at huggingface.co/<org>/<repo> before
                                                 apply. A valid token alone is not enough.
                                 "ngc"         — NGC model path including version,
                                                 e.g. "meta/llama-3.1-8b-instruct:1.0"

      model_source           — Source registry for open weight download (required).
                               Must be "huggingface" or "ngc".
                                 "huggingface" — huggingface-cli download. Requires
                                                 hf_credentials for gated models.
                                 "ngc"         — ngc registry model download-version.
                                                 Requires ngc_credentials.

      instance_type          — SageMaker instance type (required). e.g. "ml.g6e.12xlarge".

      model_revision         — HF branch, tag, or commit hash. Default "main". Baked into
                               the S3 prefix — changing it triggers a fresh download to a
                               new prefix. Ignored for NGC (version is in model_id).

      framework              — Inference framework for the shim container image. Default "vllm".
                               Currently supported: "vllm". Planned: "triton".

      extra_args             — Framework CLI flags passed to the inference server at
                               container startup. map(string) where each key is a flag name
                               (without --) and the value is the flag value, or "" for boolean
                               flags. Always overrides any flags from enable_vllm_recipe.
                               Examples:
                                 extra_args = {
                                   max-model-len = "8192"
                                   dtype         = "bfloat16"
                                   enforce-eager = ""
                                 }

      enable_vllm_recipe     — Fetch optimized vllm serve flags from recipes.vllm.ai at
                               weight-fetch time. Default false. When true, the weight-fetch
                               CodeBuild queries https://recipes.vllm.ai/<hf_org>/<hf_repo>.json
                               and writes a recipe env file to S3. launch.sh sources it at
                               container startup, applying base_args and variant extra_args
                               before any explicit extra_args (user always wins). If the model
                               has no recipe, the build logs a warning and falls back to vLLM
                               defaults — the endpoint still deploys. Only applies to
                               model_source = "huggingface" (NGC models do not have vLLM recipes).

      vllm_precision         — Precision variant to select from the vLLM recipe. Default "default"
                               (bf16). Set to "fp8" for FP8-quantized recipes when available.
                               Ignored when enable_vllm_recipe = false.

      endpoint_name          — Custom endpoint name override. null (default) auto-generates
                               as "$${project_prefix}-$${environment}-$${key}".

      async_output_s3_prefix — S3 key prefix for async inference response payloads,
                               relative to s3://<output_bucket>/<key>/. Default: "async-output/".

      ml_reservation_arn     — ARN of a SageMaker Flexible Training Plan reservation.
                               STUB — hashicorp/aws provider does not expose this attribute yet.
                               See DEVELOPER_REFERENCE.md.

      debug                  — Enable verbose logging for this endpoint's CodeBuild builds only.

      force_rebuild          — Force this endpoint's CodeBuild builds to re-run on the next apply.
  EOD

  validation {
    condition = alltrue([
      for k, v in var.sagemaker_endpoints.nim : contains(["realtime", "async"], v.endpoint_type)
    ])
    error_message = "sagemaker_endpoints.nim: endpoint_type must be \"realtime\" or \"async\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.sagemaker_endpoints.nim :
      !(startswith(v.source_image_uri, "nvcr.io/") && !v.sync_to_ecr)
    ])
    error_message = "sagemaker_endpoints.nim: sync_to_ecr = false requires an ECR source URI. nvcr.io images must be synced first."
  }

  validation {
    condition = alltrue([
      for k, v in var.sagemaker_endpoints.open_weight : contains(["huggingface", "ngc"], v.model_source)
    ])
    error_message = "sagemaker_endpoints.open_weight: model_source must be \"huggingface\" or \"ngc\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.sagemaker_endpoints.open_weight : contains(["realtime", "async"], v.endpoint_type)
    ])
    error_message = "sagemaker_endpoints.open_weight: endpoint_type must be \"realtime\" or \"async\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.sagemaker_endpoints.open_weight : contains(["vllm"], v.framework)
    ])
    error_message = "sagemaker_endpoints.open_weight: framework must be \"vllm\". \"triton\" is planned but not yet supported."
  }
}


# ---------------------------------------------------------------------------
# Platform: EKS
# ---------------------------------------------------------------------------

variable "eks_clusters" {
  type = map(object({
    vpc_id                  = string
    private_subnet_ids      = list(string)
    public_subnet_ids       = list(string)
    instance_type           = string
    kubernetes_version      = optional(string, "1.35")
    endpoint_public_access  = optional(bool, true)
    endpoint_private_access = optional(bool, true)
    public_access_cidrs     = optional(list(string), null)
    allowed_cidr_blocks     = optional(list(string), null)
    internet_gateway_id     = optional(string, null)
    cluster_log_types       = optional(list(string), ["api", "audit", "authenticator", "controllerManager", "scheduler"])
    eks_access_entries = optional(map(object({
      principal_arn = string
      type          = optional(string, "STANDARD")
      policy_associations = optional(list(object({
        policy_arn = string
        access_scope = object({
          type       = string
          namespaces = optional(list(string))
        })
      })), [])
    })), {})
    enable_autoscaling = optional(bool, false)
    debug              = optional(bool, false)
    force_rebuild      = optional(bool, false)
  }))
  default     = {}
  description = <<-EOD
    Map of EKS clusters to create. Keys are user-defined cluster labels referenced
    by eks_deployments[*].cluster_key. Empty map (default) creates no EKS resources.

    Each entry provisions an EKS Auto Mode cluster scoped to a single VPC and GPU
    instance type. Multiple entries allow different GPU families (e.g. g6e vs p5) or
    different VPCs to coexist in a single module call.

    Key naming: letters, numbers, and hyphens only.

    Fields:
      vpc_id                  — VPC to deploy the cluster into (required).
      private_subnet_ids      — Private subnets for EKS nodes and CodeBuild. Must have
                                NAT gateway outbound internet access for NGC pulls.
      public_subnet_ids       — Public subnets for load balancer placement. Must be
                                tagged kubernetes.io/role/elb=1.
      instance_type           — EC2 GPU instance type for NIM nodes (e.g. g6e.12xlarge).
                                No ml. prefix. Sets the Karpenter NodePool constraint.
      kubernetes_version      — EKS Kubernetes version. Default "1.35" (latest standard support
                                   as of January 2026, available in all regions).
      endpoint_public_access  — Enable public API server endpoint. Default true.
                                Set false for fully private clusters (requires VPN or
                                Direct Connect to reach the API from CodeBuild VPC).
      endpoint_private_access — Enable private API server endpoint. Default true.
                                Must be true when CodeBuild is VPC-placed (always the case
                                in this module).
      public_access_cidrs     — CIDR blocks allowed to reach the public API endpoint.
                                Null = allow all. Only used when endpoint_public_access = true.
                                Set to [your_office_cidr] to restrict kubectl access.
      allowed_cidr_blocks     — CIDR blocks allowed inbound to the cluster security group
                                (e.g. developer workstations, VPN, bastion subnets). These
                                CIDRs receive port 443 ingress on the cluster SG. Null = no
                                additional ingress beyond the VPC-internal CodeBuild rules.
      internet_gateway_id     — IGW ID of the consumer VPC. Creates a destroy-time fence
                                so the EKS cluster is always destroyed before the IGW,
                                preventing NLB/ENI cleanup failures from blocking VPC
                                teardown. Strongly recommended.
      cluster_log_types       — EKS control plane log types. Default: all five types
                                (api, audit, authenticator, controllerManager, scheduler).
      eks_access_entries      — Additional IAM principals granted kubectl access.
                                Map key is a unique label. Each entry may include multiple
                                policy_associations. See example below.
      enable_autoscaling      — Install the pod autoscaling stack cluster-wide (KEDA +
                                kube-prometheus-stack + DCGM exporter) so any deployment on
                                this cluster can opt into ScaledObject-based scaling by
                                setting eks_deployments[*].autoscaling. Default false.
                                See the module README "Autoscaling" section for the
                                cold-start caveats and metric-selection guidance.
      debug                   — Verbose cluster-setup CodeBuild output for this cluster only.
                                OR'd with var.debug.
      force_rebuild           — Force cluster-setup CodeBuild to re-run on next apply for
                                this cluster only. OR'd with var.force_rebuild.

    Examples:
      # Hybrid (public + private) — recommended for development:
      eks_clusters = {
        gpu = {
          vpc_id                  = aws_vpc.main.id
          private_subnet_ids      = aws_subnet.private[*].id
          public_subnet_ids       = aws_subnet.public[*].id
          instance_type           = "g6e.12xlarge"
          endpoint_public_access  = true
          endpoint_private_access = true
          public_access_cidrs     = ["203.0.113.0/24"]  # your office IP
        }
      }

      # Private-only — production (CodeBuild reaches API over VPC):
      eks_clusters = {
        gpu = {
          vpc_id                  = aws_vpc.main.id
          private_subnet_ids      = aws_subnet.private[*].id
          public_subnet_ids       = aws_subnet.public[*].id
          instance_type           = "g6e.12xlarge"
          endpoint_public_access  = false
          endpoint_private_access = true
        }
      }
  EOD
}

variable "eks_deployments" {
  # Inner maps default to {} not null. See sagemaker_endpoints for the reasoning.
  type = object({
    nim = optional(map(object({
      cluster_key                = string
      source_image_uri           = string
      enable_model_profile_cache = optional(bool, false)
      nim_type                   = optional(string, "llm")
      helm_chart_name            = optional(string, null)
      helm_chart_repo_url        = optional(string, null)
      helm_chart_version         = optional(string, null)
      helm_chart_s3_uri          = optional(string, null)
      helm_values_override       = optional(string, null)
      gpu_count                  = optional(number, null)
      replicas                   = optional(number, 1)
      namespace                  = optional(string, null)
      load_balancer_internal     = optional(bool, false)
      nlb_allowed_cidr_blocks    = optional(list(string), null)
      debug                      = optional(bool, false)
      force_rebuild              = optional(bool, false)
      additional_scripts         = optional(list(object({ source = string })), [])
      protocol                   = optional(string, "http")
      port                       = optional(number, null)
      autoscaling = optional(object({
        min_replicas     = optional(number, 1)
        max_replicas     = optional(number, 5)
        metric           = optional(string, null)
        target_value     = optional(number, null)
        scale_down_delay = optional(number, 600)
      }), null)
    })), {})
    open_weight = optional(map(object({
      cluster_key             = string
      model_id                = string
      model_source            = string
      model_revision          = optional(string, "main")
      extra_args              = optional(map(string), {})
      gpu_count               = optional(number, null)
      replicas                = optional(number, 1)
      namespace               = optional(string, null)
      load_balancer_internal  = optional(bool, false)
      nlb_allowed_cidr_blocks = optional(list(string), null)
      debug                   = optional(bool, false)
      force_rebuild           = optional(bool, false)
      additional_scripts      = optional(list(object({ source = string })), [])
      autoscaling = optional(object({
        min_replicas     = optional(number, 1)
        max_replicas     = optional(number, 5)
        metric           = optional(string, null)
        target_value     = optional(number, null)
        scale_down_delay = optional(number, 600)
      }), null)
    })), {})
  })
  # Outer object defaults to {} so .nim and .open_weight are always accessible.
  default     = {}
  description = <<-EOD
    EKS NIM deployments. Two sub-maps: nim (Helm + NGC container) and open_weight (kubectl + vLLM).

    nim entries: Helm release onto the target cluster. source_image_uri required.
    open_weight entries: raw vLLM Deployment+Service via kubectl. model_id + model_source required.

    cluster_key must match a key in eks_clusters.

    Example:
      eks_deployments = {
        nim = {
          nemotron-9b = {
            cluster_key        = "gpu"
            source_image_uri   = "nvcr.io/nim/nvidia/nvidia-nemotron-nano-9b-v2:latest"
            helm_chart_version = "2.0.3"
          }
        }
        open_weight = {
          nemotron-9b = {
            cluster_key  = "gpu"
            model_id     = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"
            model_source = "huggingface"
          }
        }
      }

    nim fields:
      cluster_key                — Key in eks_clusters identifying the target cluster (required).
      source_image_uri           — NIM container image URI (required). nvcr.io or ECR URI. The base
                                   image (synced to ECR by base-sync CodeBuild) is used directly —
                                   no shim for EKS.
      enable_model_profile_cache — Pre-sync the NGC model profile cache from S3 into the pod via
                                   an init container at startup. Default false. The S3 prefix is
                                   derived from source_image_uri and the cluster's instance_type.
      nim_type                   — Categorization of the NIM, identifying the family of model
                                   this NIM serves. Used today to drive Helm chart selection and
                                   default port for the HTTP deployment path. Future versions may
                                   use this for other selectors (e.g., default GPU sizing
                                   recommendations, monitoring presets) — keep the field's
                                   semantics broad ("kind of NIM") even though today it primarily
                                   feeds the Helm path.

                                   What `nim_type` controls today:
                                     1. Helm chart name (nim-llm, text-embedding-nim, etc.)
                                     2. Helm chart repo URL (per-family NGC path)
                                     3. Default service port (8000 for LLM/VLM, 8080 for
                                        embedding/reranking, varies for speech)
                                     4. Chart-specific value shaping (e.g., Riva uses base64-encoded
                                        NGC key; LLM/embedding use ngcAPISecret reference)

                                   When protocol = "grpc" the Helm-related effects (#1, #2, #4) are
                                   bypassed because the gRPC path deploys via raw kubectl
                                   Deployment+Service. nim_type is still meaningful for #3 (default
                                   port) and for documentation/categorization.

                                   Default "llm". Valid values:
                                     "llm"       — NVIDIA NIM for LLMs (Llama, Nemotron, Mistral, ...)
                                                   Chart: nim-llm
                                                   Repo: https://helm.ngc.nvidia.com/nim/charts
                                                   Default HTTP port: 8000
                                     "vlm"       — NVIDIA NIM for Vision Language Models.
                                                   Chart: nim-vlm
                                                   Repo: https://helm.ngc.nvidia.com/nim/charts
                                                   Default HTTP port: 8000
                                     "embedding" — NVIDIA NIM for text embedding.
                                                   Chart: text-embedding-nim
                                                   Repo: https://helm.ngc.nvidia.com/nim/nvidia/charts
                                                   Default HTTP port: 8080
                                     "reranking" — NVIDIA NIM for text reranking (RAG rerank step).
                                                   Chart: text-reranking-nim
                                                   Repo: https://helm.ngc.nvidia.com/nim/nvidia/charts
                                                   Default HTTP port: 8080
                                     "speech"    — NVIDIA Riva speech NIM (STT, TTS).
                                                   Chart: riva-api
                                                   Repo: https://helm.ngc.nvidia.com/nvidia/riva/charts
                                                   Riva-specific value shape (base64 NGC key).
                                     "custom"    — Custom / internal NIM, or a NIM that doesn't fit
                                                   the categories above (e.g. Maxine media NIMs:
                                                   SVD, Audio2Face, Studio Voice, Eye Contact, BNR).
                                                   When protocol = "http": must set helm_chart_s3_uri
                                                   (S3-hosted .tgz) OR both helm_chart_name +
                                                   helm_chart_repo_url. When protocol = "grpc":
                                                   chart info is not required (raw kubectl path).
      helm_chart_name            — Override the NGC Helm chart name. Null (default) = derived from nim_type.
      helm_chart_repo_url        — Override the base HTTPS URL for the NGC Helm chart repo.
                                   Null (default) = derived from nim_type.
      helm_chart_version         — Helm chart version to fetch from NGC. Required for NGC charts —
                                   NGC does not expose a chart index (index.yaml), so helm repo
                                   add/pull do not work. Always pin a specific version (e.g. "2.0.3").
                                   Ignored when helm_chart_s3_uri is set.
      helm_values_override       — Raw YAML string merged after the generated values file. Applied
                                   with a second -f flag so any key here wins over the generated
                                   defaults. Use for chart-specific fields the module does not
                                   generate (e.g. Riva model configs, custom resource limits).
                                   Required for nim_type = "custom" since no base values are
                                   generated for unknown chart schemas.
      helm_chart_s3_uri          — S3 URI of a pre-packaged Helm chart .tgz to deploy instead of
                                   fetching from NGC. Format: s3://bucket/path/chart-1.0.0.tgz
                                   When set, helm_chart_name, helm_chart_repo_url, and
                                   helm_chart_version are ignored.
      gpu_count                  — GPUs to request per pod replica. Default: auto-derived from the
                                   cluster's instance_type. Override only when you intentionally want
                                   fewer GPUs. Unknown instance types fall back to 1.
      replicas                   — Number of NIM pod replicas. Default 1.
      namespace                  — Kubernetes namespace. Default: the deployment key.
      load_balancer_internal     — Create an internal (VPC-only) NLB instead of internet-facing.
                                   Default false.
      debug                      — Verbose CodeBuild output for this deployment only.
      force_rebuild              — Force re-deploy on next apply regardless of input changes.
      protocol                   — Inference protocol the NIM serves. Default "http". Valid values:
                                     "http" — NIM exposes HTTP/JSON inference (default for LLM NIMs,
                                              embedding, Riva speech, vLLM). Deployed via Helm.
                                     "grpc" — NIM exposes gRPC inference (default for Maxine media
                                              NIMs: SVD, Audio2Face, Studio Voice, Eye Contact, BNR).
                                              Deployed via raw kubectl Deployment+Service since no
                                              Helm chart is published for Maxine NIMs on NGC today.
                                              See DEVELOPER_REFERENCE.md "Inference Protocols" for
                                              background on why media NIMs use gRPC.
      port                       — Service port the NIM exposes for inference. Default null →
                                   the module picks a sensible default based on protocol + nim_type:
                                     protocol="http", nim_type="llm"       → 8000
                                     protocol="http", nim_type="embedding" → 8080
                                     protocol="http", nim_type="speech"    → 8000
                                     protocol="grpc"                       → 8001 (Maxine convention)
                                   Override only when the NIM uses a non-standard port (e.g. some
                                   Triton-based NIMs serve gRPC on 50051).
      autoscaling                — When non-null, a KEDA ScaledObject is created for this
                                   deployment. The `replicas` field above becomes the initial
                                   replica count; KEDA then adjusts within [min_replicas,
                                   max_replicas] based on the metric. Requires the target
                                   cluster to have enable_autoscaling = true.
                                     min_replicas     — Floor. Default 1. Set to >=2 in prod so
                                                        the first scale-up doesn't force a
                                                        5-15 min NIM cold-start on a live request.
                                     max_replicas     — Ceiling. Default 5.
                                     metric           — Prometheus metric name to scale on.
                                                        Null (default) auto-derives from nim_type:
                                                          llm/vlm → gpu_cache_usage_perc
                                                          all others → DCGM_FI_DEV_GPU_UTIL
                                     target_value     — Threshold. Null (default) → 70 for both
                                                        metrics above. Percentage.
                                     scale_down_delay — HPA scale-down stabilization window in
                                                        seconds. Default 600 (10 min). Passed to
                                                        the underlying HPA's
                                                        behavior.scaleDown.stabilizationWindowSeconds
                                                        so oscillation near threshold doesn't trigger
                                                        replica thrash. NIMs cold-start slow; short
                                                        windows are painful. Not to be confused with
                                                        KEDA's cooldownPeriod (which only controls
                                                        scale-to-zero, not the min>=1 case).

    open_weight fields:
      cluster_key            — Key in eks_clusters identifying the target cluster (required).
      model_id               — Open weight model ID (required). HuggingFace repo ID or NGC path.
                               Same format as sagemaker_endpoints.open_weight.
      model_source           — Required. "huggingface" or "ngc". Controls which downloader
                               weight-fetch uses.
      model_revision         — HF branch, tag, or commit. Default "main". Baked into S3 prefix —
                               changing it triggers a fresh download.
      extra_args             — vLLM CLI flags passed to vllm serve. Same map(string) format as
                               sagemaker_endpoints.open_weight.extra_args.
      gpu_count              — GPUs to request per pod replica. Default: auto-derived from the
                               cluster's instance_type.
      replicas               — Number of pod replicas. Default 1.
      namespace              — Kubernetes namespace. Default: the deployment key.
      load_balancer_internal — Create an internal (VPC-only) NLB instead of internet-facing.
                               Default false.
      debug                  — Verbose CodeBuild output for this deployment only.
      force_rebuild          — Force re-deploy on next apply regardless of input changes.
      autoscaling            — Same schema as eks_deployments.nim.autoscaling above. Default
                               metric for open_weight is `gpu_cache_usage_perc` (vLLM exposes
                               it natively on /metrics).
  EOD

  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.nim :
      contains(["llm", "vlm", "embedding", "reranking", "speech", "custom"], v.nim_type)
    ])
    error_message = "eks_deployments.nim: nim_type must be one of: \"llm\", \"vlm\", \"embedding\", \"reranking\", \"speech\", \"custom\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.nim :
      v.nim_type != "custom" || v.protocol == "grpc" || (
        v.helm_chart_s3_uri != null || (v.helm_chart_name != null && v.helm_chart_repo_url != null)
      )
    ])
    error_message = "eks_deployments.nim: nim_type = \"custom\" with protocol = \"http\" requires helm_chart_s3_uri OR both helm_chart_name and helm_chart_repo_url. (protocol = \"grpc\" bypasses Helm — chart info not required.)"
  }

  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.open_weight : contains(["huggingface", "ngc"], v.model_source)
    ])
    error_message = "eks_deployments.open_weight: model_source must be \"huggingface\" or \"ngc\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.nim : contains(["http", "grpc"], v.protocol)
    ])
    error_message = "eks_deployments.nim: protocol must be \"http\" or \"grpc\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.nim :
      v.port == null || (v.port >= 1 && v.port <= 65535)
    ])
    error_message = "eks_deployments.nim: port must be null (use default) or a valid TCP port (1-65535)."
  }

  # Force an explicit network-access posture on internet-facing NIM NLBs. The k8s Service
  # loadBalancerSourceRanges field wires directly into the NLB security group; leaving it
  # unset means the NLB accepts inference requests from 0.0.0.0/0. Refusing that combo at
  # plan-time is defense-in-depth against forgetting the CIDR in an example.
  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.nim :
      v.load_balancer_internal == true || (v.nlb_allowed_cidr_blocks != null && length(v.nlb_allowed_cidr_blocks) > 0)
    ])
    error_message = "eks_deployments.nim: when load_balancer_internal = false, nlb_allowed_cidr_blocks must be a non-empty list to restrict inference endpoint access. To open explicitly to the whole internet, pass [\"0.0.0.0/0\"]."
  }
  validation {
    condition = alltrue([
      for k, v in var.eks_deployments.open_weight :
      v.load_balancer_internal == true || (v.nlb_allowed_cidr_blocks != null && length(v.nlb_allowed_cidr_blocks) > 0)
    ])
    error_message = "eks_deployments.open_weight: when load_balancer_internal = false, nlb_allowed_cidr_blocks must be a non-empty list to restrict inference endpoint access. To open explicitly to the whole internet, pass [\"0.0.0.0/0\"]."
  }
}


# ---------------------------------------------------------------------------
# Shim (TEMPORARY — remove once NVIDIA adds native SageMaker NIM support)
# ---------------------------------------------------------------------------

variable "shim_config" {
  type = object({
    nim_cmd            = optional(string, "/opt/nim/start_server.sh")
    nim_entrypoint     = optional(string, "/opt/nvidia/nvidia_entrypoint.sh")
    caddy_backend_port = optional(number, null)
    cuda_driver_label  = optional(string, null)
  })
  default     = {}
  description = <<-EOD
    Module-level defaults for the SageMaker shim container (Caddy proxy + framework
    launcher). The shim is a permanent SageMaker requirement: SageMaker hardcodes
    POST /invocations and GET /ping, which no inference framework serves natively.
    Caddy rewrites these paths to the framework's native API paths.

    These values apply to all NIM endpoints. A per-endpoint shim block inside
    sagemaker_endpoints takes priority over these defaults for that specific endpoint —
    same hierarchy as var.debug / var.force_rebuild vs. per-endpoint debug / force_rebuild.
    Open weight endpoints (model_id set) use framework-specific defaults automatically.

    Omit this variable entirely for standard NGC NIMs — the defaults work out of the box.

    nim_cmd            — Shell command to start the NIM server process.
                         Default suits all standard NGC NIMs.
                         Alpamayo: "python /workspace/web/backend/edgellm_server.py"

    nim_entrypoint     — Path to the NIM entrypoint script in the base image. Newer NIM
                         versions omit nvidia_entrypoint.sh; launch.sh falls back to
                         nim_cmd directly when the path does not exist.

    caddy_backend_port — Port Caddy routes requests to (the NIM's external HTTP API port).
                         Null (default) = auto-detected at container startup from the NIM
                         image's own NIM_HTTP_API_PORT env var (standard NIMs set this to
                         8000). Only set this for custom NIMs that serve on a different
                         port (e.g. Alpamayo uses 8001).
                         Named caddy_backend_port — not nim_backend_port — to avoid
                         colliding with the NIM image's own NIM_BACKEND_PORT env var,
                         which vLLM-based NIMs use to configure vLLM's internal listen port.

    cuda_driver_label  — CUDA version string baked into the shim image as Docker label:
                           LABEL com.amazonaws.sagemaker.inference.cuda.verified_versions
                         SageMaker reads this to auto-select an inference AMI with a
                         matching CUDA driver. Null (default) = SageMaker picks the default.
                         See DEVELOPER_REFERENCE.md — known AMI bug history.
  EOD
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------

variable "ecr_image_retention_days" {
  type        = number
  default     = null
  description = <<-EOD
    Number of days before tagged images in the ECR repository are automatically expired.
    Null (default) = no age expiry — a count-based policy keeps the last 10 images instead.

    Setting this handles the main orphan scenario: changing source_image_uri version
    (e.g. 1.8.3 → 1.9.0) leaves old {image}-{old-version}-base and {image}-{old-version}-shim
    tags behind. Each shim image is ~10 GB, so orphans accumulate cost quickly across
    many model versions.

    Untagged images are always expired after 14 days regardless of this setting.

    A retention of 30–90 days is a reasonable default — long enough to survive a rollback
    window without accumulating many stale versions.
  EOD

  validation {
    condition     = var.ecr_image_retention_days == null || var.ecr_image_retention_days >= 1
    error_message = "ecr_image_retention_days must be at least 1."
  }
}

variable "ecr_force_delete" {
  type        = bool
  default     = true
  description = <<-EOD
    When true, the module-managed ECR repository is deletable even when it contains
    images. Required for clean terraform destroy after base-sync or shim CodeBuild
    builds have pushed images — which they almost always have after a first apply.

    Set false only if you need Terraform to refuse destroy while images remain.
  EOD
}

variable "s3_force_destroy" {
  type        = bool
  default     = true
  description = <<-EOD
    When true, all module-managed S3 buckets are deletable even when non-empty.
    Required for clean terraform destroy when caches, build zips, or async outputs
    are present — which they almost always are after a first apply.

    Set false only if you need Terraform to refuse destroy while objects remain
    (e.g. a compliance gate that treats the S3 bucket as the last line of defence).
  EOD
}

variable "model_profile_cache_retention_days" {
  type        = number
  default     = null
  description = <<-EOD
    Number of days before objects in the model profile cache bucket are automatically
    expired. Null (default) = no expiration — objects persist until manually deleted.

    Setting this handles the two main orphan scenarios:
      - Changing instance_type: old nim-cache/{key}/{old_type}/ prefix becomes dead data.
      - Changing a sagemaker_endpoints key: old nim-cache/{old_key}/ prefix is abandoned.

    Model profile caches are large (tens of GB per endpoint). A retention of 30–90 days
    is a reasonable default to auto-clean orphaned prefixes without risking a valid cache
    being expired mid-deployment.

    Applies to both current and noncurrent object versions (versioning is enabled on the
    cache bucket to protect against partial uploads overwriting known-good artifacts).
  EOD

  validation {
    condition     = var.model_profile_cache_retention_days == null || var.model_profile_cache_retention_days >= 1
    error_message = "model_profile_cache_retention_days must be at least 1."
  }
}

# ---------------------------------------------------------------------------
# Cache path
# ---------------------------------------------------------------------------

variable "cache_path" {
  type        = string
  default     = "/opt/nim/.cache"
  description = <<-EOD
    Filesystem path inside the container where NIM reads its cached model artifacts.
    At startup, launch.sh syncs from S3 (MODEL_PROFILE_CACHE env var) into this path.

    Standard NGC NIMs use /opt/nim/.cache (default). Custom NIMs may require a
    different path — see the NIM image documentation.
  EOD
}

# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------

variable "debug" {
  type        = bool
  default     = false
  description = <<-EOD
    Enable verbose logging in all CodeBuild builds — set -x, timestamps on each step,
    elapsed time per phase, and extended output (full profile lists, docker pull progress).

    Applies globally to all CodeBuild projects. To enable verbose logging for a single
    endpoint's builds only, set debug = true inside that sagemaker_endpoints or
    eks_clusters / eks_deployments entry.
  EOD
}

variable "force_rebuild" {
  type        = bool
  default     = false
  description = <<-EOD
    Force all CodeBuild builds (base-sync, shim, model-profile-cache, cluster-setup,
    nim-deploy) to re-run on the next apply regardless of whether inputs changed.
    Useful for retesting a build without touching any source files.

    Set back to false after the forced rebuild to restore normal change-detection behavior.
    To force-rebuild a single endpoint or cluster's builds only, set force_rebuild = true
    inside that sagemaker_endpoints, eks_clusters, or eks_deployments entry.
  EOD
}
