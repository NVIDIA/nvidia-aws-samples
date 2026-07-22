
# --- Identity ---
locals {
  account_id = data.aws_caller_identity.current.account_id
}

# --- Debug / force_rebuild ---
# rebuild_token is computed per CodeBuild map entry (base_sync_map, shim_map, cache_map).
# When an entry's force_rebuild = true, timestamp() is used as the token — it changes
# every plan, causing that entry's terraform_data trigger to re-fire on every apply.
# When false, the stable sentinel "stable" never changes and no spurious builds fire.
# The global var.force_rebuild and var.debug are OR-ed with per-entry values in the maps.

# --- Resource naming ---
locals {
  name_prefix   = "${var.project_prefix}-${var.environment}"
  ecr_repo_name = local.name_prefix
}

# --- SageMaker path split ---
# var.sagemaker_endpoints.nim:         endpoints using NIM container images
# var.sagemaker_endpoints.open_weight: endpoints using open weights + framework shim

# --- EKS path split ---
# var.eks_deployments.nim:         deployments using NIM container images
# var.eks_deployments.open_weight: deployments using open weights + vLLM

# --- NGC image detection (module-level) ---
# True when ANY endpoint (SageMaker NIM or EKS) uses an nvcr.io source URI — signals
# that NGC credentials must be present for base-sync and model-profile-cache builds.
locals {
  any_ngc_endpoint = anytrue(concat(
    [for _, v in var.sagemaker_endpoints.nim : can(regex("^nvcr\\.io/", v.source_image_uri))],
    [for _, v in var.eks_deployments.nim : can(regex("^nvcr\\.io/", v.source_image_uri))],
  ))
}

# --- SageMaker endpoint sets ---
#
# endpoints_to_sync: endpoints where sync_to_ecr = true (need base-sync build).
# endpoints_with_cache: endpoints where enable_model_profile_cache = true.
locals {
  endpoints_to_sync = {
    for k, v in var.sagemaker_endpoints.nim : k => v
    if v.sync_to_ecr
  }

  endpoints_with_cache = {
    for k, v in var.sagemaker_endpoints.nim : k => v
    if v.enable_model_profile_cache
  }
}

# --- Image URI parsing ---
#
# Derives canonical identifiers from source_image_uri for deterministic ECR tagging
# and S3 cache namespacing. Two endpoints with the same source_image_uri share the
# same base image, shim image, and (when instance_type also matches) S3 cache entry.
#
# Assumes one colon separating image path from version tag — standard for nvcr.io
# and ECR URIs (no registry port numbers).
#
# Example: "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
#   uri_image_name → "llama-3.1-8b-instruct"
#   uri_version    → "1.8.3"
#   uri_canonical  → "llama-3.1-8b-instruct-1.8.3"
#   uri_base_tag   → "llama-3.1-8b-instruct-1.8.3-base"
#   uri_shim_tag   → "llama-3.1-8b-instruct-1.8.3-shim"
locals {
  # All source URIs across all platforms — used for ECR tag derivation and deduplication.
  # Only NIM endpoints have source_image_uri; open weight endpoints use model_id instead.
  all_source_uris = toset(concat(
    [for k, v in var.sagemaker_endpoints.nim : v.source_image_uri],
    [for k, v in var.eks_deployments.nim : v.source_image_uri],
  ))

  uri_image_name = {
    for uri in local.all_source_uris :
    uri => element(
      split("/", split(":", uri)[0]),
      length(split("/", split(":", uri)[0])) - 1
    )
  }

  uri_version = {
    for uri in local.all_source_uris :
    uri => length(split(":", uri)) > 1 ? split(":", uri)[1] : "latest"
  }

  uri_canonical = {
    for uri in local.all_source_uris :
    uri => "${local.uri_image_name[uri]}-${local.uri_version[uri]}"
  }

  uri_base_tag = {
    for uri, c in local.uri_canonical : uri => "${c}-base"
  }

  uri_shim_tag = {
    for uri, c in local.uri_canonical : uri => "${c}-shim"
  }

  # URIs where sync_to_ecr = false — the source_image_uri IS the ECR image already.
  # For these, the NGC tag-parsing pipeline produces wrong values; bypass it.
  uri_no_sync = toset([
    for k, v in var.sagemaker_endpoints.nim : v.source_image_uri if !v.sync_to_ecr
  ])

  # Effective canonical / base_tag / shim_tag:
  #   mirror_to_ecr = true  → use the NGC-derived values from uri_canonical/uri_base_tag/uri_shim_tag
  #   mirror_to_ecr = false → ECR URI tag IS the base_tag; strip "-base" suffix for canonical/shim
  uri_effective_canonical = {
    for uri in local.all_source_uris :
    uri => contains(local.uri_no_sync, uri) ? trimsuffix(split(":", uri)[1], "-base") : local.uri_canonical[uri]
  }

  uri_effective_base_tag = {
    for uri in local.all_source_uris :
    uri => contains(local.uri_no_sync, uri) ? split(":", uri)[1] : local.uri_base_tag[uri]
  }

  uri_effective_shim_tag = {
    for uri in local.all_source_uris :
    uri => contains(local.uri_no_sync, uri) ? "${trimsuffix(split(":", uri)[1], "-base")}-shim" : local.uri_shim_tag[uri]
  }

  # Per-endpoint lookup used in main.tf to resolve the correct ECR shim tag.
  # Only NIM endpoints — open weight endpoints have their own open_weight_endpoint_to_shim_tag.
  endpoint_to_shim_tag = {
    for k, v in var.sagemaker_endpoints.nim : k => local.uri_effective_shim_tag[v.source_image_uri]
  }
}

# --- Per-URI CodeBuild maps ---
#
# One CodeBuild project per unique source URI (and per unique URI × instance_type
# combo for caching). Keys are canonical names used as for_each identifiers and
# as project name suffixes (dots replaced with dashes for CodeBuild name validity).
#
# base_sync_map: keyed by canonical name. One entry per URI where sync_to_ecr = true.
#                Covers both SageMaker NIM and EKS NIM source URIs.
# shim_map:      two kinds of entries merged together:
#                  NIM: keyed by effective canonical, one per unique source_image_uri
#                  Open-weight: keyed by "ow--{framework}", one per unique framework
#                  (e.g. "ow--vllm"). All open-weight endpoints sharing a framework
#                  share one shim image built FROM the public framework base image.
# cache_map:     keyed by "{safe_canonical}--{instance_type}[--{model_profile}]".
#                One entry per unique (URI, instance_type, model_profile) combo.
#                Spread operator deduplicates identical combos from multiple endpoints.
locals {
  # EKS NIM deployments where sync_to_ecr should happen.
  # Open-weight EKS deployments pull vLLM from DockerHub directly — no ECR sync needed.
  eks_endpoints_to_sync = var.eks_deployments.nim

  base_sync_map = {
    for uri in toset(concat(
      [for k, v in local.endpoints_to_sync : v.source_image_uri],
      [for k, v in local.eks_endpoints_to_sync : v.source_image_uri],
    )) :
    local.uri_canonical[uri] => {
      source_image_uri = uri
      base_tag         = local.uri_base_tag[uri]
      force_rebuild = var.force_rebuild || anytrue(concat(
        [for k, v in local.endpoints_to_sync : v.force_rebuild if v.source_image_uri == uri],
        [for k, v in local.eks_endpoints_to_sync : v.force_rebuild if v.source_image_uri == uri],
      ))
      debug = var.debug || anytrue(concat(
        [for k, v in local.endpoints_to_sync : v.debug if v.source_image_uri == uri],
        [for k, v in local.eks_endpoints_to_sync : v.debug if v.source_image_uri == uri],
      ))
    }
  }

  shim_map = merge(
    # NIM entries — one per unique source_image_uri in sagemaker_endpoints.
    {
      for uri in toset([for k, v in var.sagemaker_endpoints.nim : v.source_image_uri]) :
      local.uri_effective_canonical[uri] => {
        source_image_uri   = uri
        base_tag           = local.uri_effective_base_tag[uri]
        shim_tag           = local.uri_effective_shim_tag[uri]
        sync_to_ecr        = !contains(local.uri_no_sync, uri)
        base_sync_project  = !contains(local.uri_no_sync, uri) ? "${local.name_prefix}-base-sync-${replace(local.uri_canonical[uri], ".", "-")}" : ""
        force_rebuild      = var.force_rebuild || anytrue([for k, v in var.sagemaker_endpoints.nim : v.force_rebuild if v.source_image_uri == uri])
        debug              = var.debug || anytrue([for k, v in var.sagemaker_endpoints.nim : v.debug if v.source_image_uri == uri])
        nim_cmd            = try([for _, v in var.sagemaker_endpoints.nim : v.shim_config.nim_cmd if v.source_image_uri == uri && v.shim_config.nim_cmd != null][0], var.shim_config.nim_cmd)
        nim_entrypoint     = try([for _, v in var.sagemaker_endpoints.nim : v.shim_config.nim_entrypoint if v.source_image_uri == uri && v.shim_config.nim_entrypoint != null][0], var.shim_config.nim_entrypoint)
        caddy_backend_port = try([for _, v in var.sagemaker_endpoints.nim : v.shim_config.caddy_backend_port if v.source_image_uri == uri && v.shim_config.caddy_backend_port != null][0], var.shim_config.caddy_backend_port)
        cuda_driver_label  = try([for _, v in var.sagemaker_endpoints.nim : v.shim_config.cuda_driver_label if v.source_image_uri == uri && v.shim_config.cuda_driver_label != null][0], var.shim_config.cuda_driver_label)
      }
    },
    # Open weight entries — one per unique framework. All vLLM endpoints share one shim image.
    # Builds FROM the public framework base image; no base-sync step needed.
    {
      for fw in toset([for k, v in var.sagemaker_endpoints.open_weight : v.framework]) :
      "ow--${fw}" => {
        source_image_uri   = local.framework_base_images[fw]
        base_tag           = ""
        shim_tag           = local.open_weight_shim_tag_by_framework[fw]
        sync_to_ecr        = false
        base_sync_project  = ""
        force_rebuild      = var.force_rebuild || anytrue([for k, v in var.sagemaker_endpoints.open_weight : v.force_rebuild if v.framework == fw])
        debug              = var.debug || anytrue([for k, v in var.sagemaker_endpoints.open_weight : v.debug if v.framework == fw])
        nim_cmd            = ""
        nim_entrypoint     = var.shim_config.nim_entrypoint
        caddy_backend_port = null
        cuda_driver_label  = null
      }
    }
  )

  cache_map = {
    for key, entries in {
      for k, v in local.endpoints_with_cache :
      "${replace(local.uri_effective_canonical[v.source_image_uri], ".", "-")}--${replace(replace(v.instance_type, "ml.", ""), ".", "-")}${v.model_profile != null ? "--${replace(v.model_profile, "_", "-")}" : ""}" => {
        source_image_uri  = v.source_image_uri
        instance_type     = replace(v.instance_type, "ml.", "")
        model_profile     = v.model_profile != null ? v.model_profile : ""
        cache_prefix      = "nim-cache/${local.uri_effective_canonical[v.source_image_uri]}/${replace(v.instance_type, "ml.", "")}"
        base_tag          = local.uri_effective_base_tag[v.source_image_uri]
        sync_to_ecr       = v.sync_to_ecr
        base_sync_project = v.sync_to_ecr ? "${local.name_prefix}-base-sync-${replace(local.uri_canonical[v.source_image_uri], ".", "-")}" : ""
        force_rebuild     = var.force_rebuild || v.force_rebuild
        debug             = var.debug || v.debug
      }...
    } : key => entries[0]
  }
}

# --- EKS GPU count resolution ---
#
# Maps EC2 instance type → number of GPUs on that instance.
# Used to set nvidia.com/gpu resource requests/limits so the pod can access all
# GPUs on the node (required for multi-GPU model profiles to function — see
# DEVELOPER_REFERENCE.md "GPU resource requests and the NVIDIA device plugin").
#
# gpu_count override in eks_deployments takes precedence when set (non-null).
# Unknown instance types fall back to 1 (safe — the user must set gpu_count explicitly).
locals {
  instance_gpu_count = {
    # g5 — A10G 24 GB
    "g5.xlarge"   = 1
    "g5.2xlarge"  = 1
    "g5.4xlarge"  = 1
    "g5.8xlarge"  = 1
    "g5.12xlarge" = 4
    "g5.16xlarge" = 1
    "g5.24xlarge" = 4
    "g5.48xlarge" = 8
    # g6 — L4 24 GB
    "g6.xlarge"   = 1
    "g6.2xlarge"  = 1
    "g6.4xlarge"  = 1
    "g6.8xlarge"  = 1
    "g6.12xlarge" = 4
    "g6.16xlarge" = 1
    "g6.24xlarge" = 4
    "g6.48xlarge" = 8
    # g6e — L40S 48 GB
    "g6e.xlarge"   = 1
    "g6e.2xlarge"  = 1
    "g6e.4xlarge"  = 1
    "g6e.8xlarge"  = 1
    "g6e.12xlarge" = 4
    "g6e.24xlarge" = 4
    "g6e.48xlarge" = 8
    # p3 — V100 16 GB
    "p3.2xlarge"    = 1
    "p3.8xlarge"    = 4
    "p3.16xlarge"   = 8
    "p3dn.24xlarge" = 8
    # p4d — A100 40 GB
    "p4d.24xlarge" = 8
    # p4de — A100 80 GB
    "p4de.24xlarge" = 8
    # p5 — H100 80 GB SXM
    "p5.48xlarge" = 8
    # p5e/p5en — H200
    "p5e.48xlarge"  = 8
    "p5en.48xlarge" = 8
  }

  # Per-deployment resolved GPU count — kept separate per path so NIM and open-weight
  # deployments with the same key name don't collide. merge() is last-wins on duplicate
  # keys, which would silently drop one entry and produce the wrong GPU count.
  #
  # Resolution order:
  #   1. explicit gpu_count in eks_deployments (non-null) → use directly
  #   2. auto-derived from cluster instance_type via instance_gpu_count table
  #   3. fallback: 1 (unknown instance type — set gpu_count explicitly)
  eks_nim_gpu_count = {
    for k, v in var.eks_deployments.nim :
    k => coalesce(
      v.gpu_count,
      try(local.instance_gpu_count[var.eks_clusters[v.cluster_key].instance_type], null),
      1
    )
  }

  eks_ow_gpu_count = {
    for k, v in var.eks_deployments.open_weight :
    k => coalesce(
      v.gpu_count,
      try(local.instance_gpu_count[var.eks_clusters[v.cluster_key].instance_type], null),
      1
    )
  }
}

# --- EKS NIM defaults by nim_type ---
#
# Maps nim_type to the NGC Helm chart info + default HTTP service port.
# "custom" has no entry here — custom NIMs either supply chart info explicitly
# (helm_chart_name + helm_chart_repo_url, OR helm_chart_s3_uri) or use the gRPC
# raw-kubectl path (protocol = "grpc") which bypasses Helm entirely.
#
# Resolved per-deployment in eks_helm_chart_name / eks_helm_chart_repo_url /
# eks_nim_resolved_port:
#   explicit override > nim_type default
locals {
  nim_chart_defaults = {
    llm = {
      helm_chart_name     = "nim-llm"
      helm_chart_repo_url = "https://helm.ngc.nvidia.com/nim/charts"
      default_http_port   = 8000
    }
    vlm = {
      helm_chart_name     = "nim-vlm"
      helm_chart_repo_url = "https://helm.ngc.nvidia.com/nim/charts"
      default_http_port   = 8000
    }
    embedding = {
      helm_chart_name     = "text-embedding-nim"
      helm_chart_repo_url = "https://helm.ngc.nvidia.com/nim/nvidia/charts"
      default_http_port   = 8080
    }
    reranking = {
      helm_chart_name     = "text-reranking-nim"
      helm_chart_repo_url = "https://helm.ngc.nvidia.com/nim/nvidia/charts"
      default_http_port   = 8080
    }
    speech = {
      helm_chart_name     = "riva-api"
      helm_chart_repo_url = "https://helm.ngc.nvidia.com/nvidia/riva/charts"
      default_http_port   = 8000
    }
  }

  # Custom NIMs don't have a default port in the table above — fall back to 8000
  # if the customer didn't supply one. They can override via the `port` field.
  eks_nim_custom_default_port = 8000

  # gRPC default port (Maxine NIM convention). Override via per-deployment `port`.
  eks_nim_grpc_default_port = 8001

  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  eks_helm_chart_name = {
    for k, v in var.eks_deployments.nim :
    k => v.helm_chart_name != null ? v.helm_chart_name : (
      v.nim_type != "custom" ? local.nim_chart_defaults[v.nim_type].helm_chart_name : null
    )
  }

  eks_helm_chart_repo_url = {
    for k, v in var.eks_deployments.nim :
    k => v.helm_chart_repo_url != null ? v.helm_chart_repo_url : (
      v.nim_type != "custom" ? local.nim_chart_defaults[v.nim_type].helm_chart_repo_url : null
    )
  }

  # Effective service port per deployment. Resolution order:
  #   1. Explicit `port` value from the customer (highest priority)
  #   2. protocol = "grpc" → gRPC default port (8001)
  #   3. protocol = "http" → nim_type's default_http_port (or 8000 fallback for custom)
  eks_nim_resolved_port = {
    for k, v in var.eks_deployments.nim :
    k => v.port != null ? v.port : (
      v.protocol == "grpc" ? local.eks_nim_grpc_default_port : (
        v.nim_type != "custom" ? local.nim_chart_defaults[v.nim_type].default_http_port : local.eks_nim_custom_default_port
      )
    )
  }
}

# --- EKS per-deployment autoscaling resolution ---
#
# Deployments with autoscaling = null keep static replicas (current behavior).
# When set, resolves defaults for metric + target_value based on the path:
#
#   NIM path (nim-llm/nim-vlm charts):
#     llm/vlm → gpu_cache_usage_perc — the NIM Helm chart re-exports vLLM
#              metrics WITHOUT the vllm: prefix. Confirmed against
#              docs.nvidia.com/nim/large-language-models observability page
#              and the operator autoscaling sample which uses the bare name.
#              Target: 0.7 (70% KV cache saturation).
#     embedding/reranking/speech/custom → DCGM_FI_DEV_GPU_UTIL — no
#              request-load metric is universally exposed; fall back to
#              per-pod GPU util from the dcgm-exporter DaemonSet.
#              Target: 70 (percent).
#
#   Open-weight path (vllm/vllm-openai image, no NIM chart):
#     Uses vllm:kv_cache_usage_perc — vLLM V1 renamed gpu_cache_usage_perc
#     to kv_cache_usage_perc and always emits with the vllm: prefix from
#     the raw /metrics endpoint. Target: 0.7.
#
# Threshold formats differ by metric family:
#   gpu_cache_usage_perc / vllm:kv_cache_usage_perc → 0.0..1.0 fraction
#   DCGM_FI_DEV_GPU_UTIL → 0..100 percent
# Passed through to the buildspec as a string; the Prometheus PromQL comparison
# is scale-agnostic so the correct format for the chosen metric is on the caller.
locals {
  autoscaling_metric_defaults = {
    llm       = { metric = "gpu_cache_usage_perc", target = 0.7 }
    vlm       = { metric = "gpu_cache_usage_perc", target = 0.7 }
    embedding = { metric = "DCGM_FI_DEV_GPU_UTIL", target = 70 }
    reranking = { metric = "DCGM_FI_DEV_GPU_UTIL", target = 70 }
    speech    = { metric = "DCGM_FI_DEV_GPU_UTIL", target = 70 }
    custom    = { metric = "DCGM_FI_DEV_GPU_UTIL", target = 70 }
  }

  eks_nim_autoscaling_resolved = {
    for k, v in var.eks_deployments.nim :
    k => v.autoscaling == null ? null : {
      min_replicas     = v.autoscaling.min_replicas
      max_replicas     = v.autoscaling.max_replicas
      metric           = v.autoscaling.metric != null ? v.autoscaling.metric : local.autoscaling_metric_defaults[v.nim_type].metric
      target_value     = v.autoscaling.target_value != null ? v.autoscaling.target_value : local.autoscaling_metric_defaults[v.nim_type].target
      scale_down_delay = v.autoscaling.scale_down_delay
    }
  }

  eks_ow_autoscaling_resolved = {
    for k, v in var.eks_deployments.open_weight :
    k => v.autoscaling == null ? null : {
      min_replicas     = v.autoscaling.min_replicas
      max_replicas     = v.autoscaling.max_replicas
      metric           = v.autoscaling.metric != null ? v.autoscaling.metric : "vllm:kv_cache_usage_perc"
      target_value     = v.autoscaling.target_value != null ? v.autoscaling.target_value : 0.7
      scale_down_delay = v.autoscaling.scale_down_delay
    }
  }
}

# --- EKS per-deployment cache prefix ---
#
# Cache prefix for S3 sync: nim-cache/<canonical>/<instance_type>
# Uses the cluster's instance_type (raw EC2 type, no ml. prefix — same key EKS uses natively).
# When a deployment has enable_model_profile_cache = true, the init container syncs this prefix.
locals {
  # All nim deployment keys are present; null when enable_model_profile_cache = false.
  # Avoids a filtered-map key-miss when the module references this for every nim entry.
  eks_cache_prefix = {
    for k, v in var.eks_deployments.nim :
    k => v.enable_model_profile_cache ? "nim-cache/${local.uri_canonical[v.source_image_uri]}/${var.eks_clusters[v.cluster_key].instance_type}" : null
  }
}

# --- Per-endpoint resolved names ---
#
# Resolves each SageMaker endpoint's name: custom endpoint_name when set, otherwise
# auto-generated as "{name_prefix}-{key}". Scoped to sagemaker_ so it doesn't
# collide when EKS endpoint name locals are added in Phase 3.
locals {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  # Separate nim/ow locals avoid merge() key collision when both maps share a key.
  sagemaker_endpoint_names_nim = {
    for k, v in var.sagemaker_endpoints.nim :
    k => v.endpoint_name != null ? v.endpoint_name : "${local.name_prefix}-${k}-nim-${random_id.endpoint_suffix_nim[k].hex}"
  }

  sagemaker_endpoint_names_ow = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => v.endpoint_name != null ? v.endpoint_name : "${local.name_prefix}-${k}-ow-${random_id.endpoint_suffix_ow[k].hex}"
  }

  # Model names use a content-keyed suffix (random_id.model_content_suffix_nim /
  # random_id.model_content_suffix_open_weight) separate from endpoint names
  # (random_id.endpoint_suffix_nim / _ow). When model image or environment changes,
  # the model gets a new name so create_before_destroy works without a name clash
  # during SageMaker's async model deletion.
  sagemaker_model_names_nim = {
    for k in keys(var.sagemaker_endpoints.nim) :
    k => "${local.name_prefix}-${k}-nim-${random_id.model_content_suffix_nim[k].hex}"
  }

  sagemaker_model_names_ow = {
    for k in keys(var.sagemaker_endpoints.open_weight) :
    k => "${local.name_prefix}-${k}-ow-${random_id.model_content_suffix_open_weight[k].hex}"
  }
}


# --- Resolved credentials ---
#
# Priority: direct value > Secrets Manager ARN.
# Mutual exclusion (can't set both) is validated in variables.tf per-object.
locals {
  # Extracts a credential value from a Secrets Manager secret_string.
  # Handles three formats automatically:
  #   1. JSON with "access-key" key  → jsondecode(s)["access-key"]
  #   2. JSON with any single key    → values(jsondecode(s))[0]
  #   3. Plain string                → s as-is
  ngc_secret_raw = try(data.aws_secretsmanager_secret_version.ngc_api_key[0].secret_string, null)
  hf_secret_raw  = try(data.aws_secretsmanager_secret_version.hf_token[0].secret_string, null)

  ngc_api_key = var.ngc_credentials != null ? (
    var.ngc_credentials.api_key != null
    ? var.ngc_credentials.api_key
    : try(
      jsondecode(local.ngc_secret_raw)["access-key"],
      values(jsondecode(local.ngc_secret_raw))[0],
      local.ngc_secret_raw
    )
  ) : null

  hf_token = var.hf_credentials != null ? (
    var.hf_credentials.token != null
    ? var.hf_credentials.token
    : try(
      jsondecode(local.hf_secret_raw)["access-key"],
      values(jsondecode(local.hf_secret_raw))[0],
      local.hf_secret_raw
    )
  ) : null

  # CodeBuild environment_variable dispatch for NGC and HF credentials.
  # When secret_arn is set: use SECRETS_MANAGER type with a reference string so
  #   CodeBuild fetches the value at build start (secretsmanager:GetSecretValue).
  #   The raw value never lands in Terraform state or CodeBuild project config.
  # When api_key/token is set (development-only path): use PLAINTEXT type.
  # Format for SECRETS_MANAGER reference:
  #   Plaintext secret:  "<arn>"       (no colons — CodeBuild returns whole value)
  #   Key/value secret:  "<arn>:<key>::"  (extracts the named JSON key)
  ngc_cb_env_value = var.ngc_credentials == null ? null : (
    var.ngc_credentials.secret_arn != null
    ? (
      var.ngc_credentials.secret_json_key != null
      ? "${var.ngc_credentials.secret_arn}:${var.ngc_credentials.secret_json_key}::"
      : var.ngc_credentials.secret_arn
    )
    : var.ngc_credentials.api_key
  )
  ngc_cb_env_type = var.ngc_credentials != null && var.ngc_credentials.secret_arn != null ? "SECRETS_MANAGER" : "PLAINTEXT"

  hf_cb_env_value = var.hf_credentials == null ? null : (
    var.hf_credentials.secret_arn != null
    ? (
      var.hf_credentials.secret_json_key != null
      ? "${var.hf_credentials.secret_arn}:${var.hf_credentials.secret_json_key}::"
      : var.hf_credentials.secret_arn
    )
    : var.hf_credentials.token
  )
  hf_cb_env_type = var.hf_credentials != null && var.hf_credentials.secret_arn != null ? "SECRETS_MANAGER" : "PLAINTEXT"
}

# --- Open weight locals ---
#
# Framework base images — the FROM image for each open weight shim build.
# The shim is framework-generic (same image regardless of model); weights are mounted
# at /opt/ml/model by SageMaker via ModelDataUrl before the container starts.
#
# weight_fetch_map:     one CodeBuild project per unique (model_id, model_source) combo.
#                       Downloads model weights to S3 open-weights/{source}/{slug}/.
# open_weight_shim_map: one CodeBuild project per unique framework.
#                       Builds the Caddy + launch script shim FROM the framework base image.
locals {
  framework_base_images = {
    vllm = "vllm/vllm-openai:latest"
  }

  # Normalized model ID slug: replace / and . with - for use in S3 keys, ECR tags, and resource names.
  # Covers both SageMaker and EKS open-weight deployments.
  model_id_slug = {
    for model_id in toset(concat(
      [for k, v in var.sagemaker_endpoints.open_weight : v.model_id],
      [for k, v in var.eks_deployments.open_weight : v.model_id],
    )) :
    model_id => lower(replace(replace(model_id, "/", "-"), ".", "-"))
  }

  # S3 prefix for model weights: open-weights/{model_source}/{model_slug}/{revision}/
  # model_revision is baked in so changing it = new prefix = fresh download.
  # For NGC the revision is already embedded in model_id (org/model:version); we still
  # include model_revision in the key for consistency, defaulting to "main".
  open_weight_s3_prefix = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => "open-weights/${v.model_source}/${local.model_id_slug[v.model_id]}/${v.model_revision}"
  }

  # Same prefix formula for EKS open-weight deployments.
  # SageMaker and EKS entries sharing the same model produce the same prefix — no duplicate download.
  eks_open_weight_s3_prefix = {
    for k, v in var.eks_deployments.open_weight :
    k => "open-weights/${v.model_source}/${local.model_id_slug[v.model_id]}/${v.model_revision}"
  }

  # Rendered extra_args for EKS open-weight deployments (same logic as extra_args_str for SageMaker).
  eks_extra_args_str = {
    for k, v in var.eks_deployments.open_weight :
    k => length(v.extra_args) > 0 ? join(" ", [for flag, val in v.extra_args : (val == "" || val == "true") ? "--${flag}" : "--${flag} ${val}"]) : null
  }

  # ECR shim tag per framework — model-independent, same image for all models using that framework.
  open_weight_shim_tag_by_framework = {
    for fw in toset([for k, v in var.sagemaker_endpoints.open_weight : v.framework]) :
    fw => "${fw}-open-weight-shim"
  }

  # Per-endpoint shim tag for main.tf ContainerHostname / image URI resolution.
  open_weight_endpoint_to_shim_tag = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => local.open_weight_shim_tag_by_framework[v.framework]
  }

  # extra_args map(string) → shell flag string.
  # Keys are flag names (without --); value "" or "true" = boolean flag (no value emitted).
  # Map keys are sorted alphabetically by Terraform; named flags are order-independent.
  extra_args_str = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => length(v.extra_args) > 0 ? join(" ", [for flag, val in v.extra_args : (val == "" || val == "true") ? "--${flag}" : "--${flag} ${val}"]) : null
  }

  # One CodeBuild weight-fetch project per unique (model_source, model_slug, revision).
  # Key: "{model_source}--{model_slug}--{revision}" — safe for CodeBuild project name suffix.
  # Covers both SageMaker and EKS open-weight deployments. SageMaker + EKS entries sharing
  # the same model produce one CodeBuild project and one S3 download — no duplication.
  # enable_vllm_recipe is OR-d across entries; try() handles EKS entries that lack it.
  weight_fetch_map = {
    for key, entries in {
      for k, v in merge(var.sagemaker_endpoints.open_weight, var.eks_deployments.open_weight) :
      "${v.model_source}--${local.model_id_slug[v.model_id]}--${v.model_revision}" => {
        model_id           = v.model_id
        model_source       = v.model_source
        model_revision     = v.model_revision
        s3_prefix          = "open-weights/${v.model_source}/${local.model_id_slug[v.model_id]}/${v.model_revision}"
        force_rebuild      = var.force_rebuild || v.force_rebuild
        debug              = var.debug || v.debug
        enable_vllm_recipe = try(v.enable_vllm_recipe, false)
      }...
      } : key => {
      model_id           = entries[0].model_id
      model_source       = entries[0].model_source
      model_revision     = entries[0].model_revision
      s3_prefix          = entries[0].s3_prefix
      force_rebuild      = anytrue([for e in entries : e.force_rebuild])
      debug              = anytrue([for e in entries : e.debug])
      enable_vllm_recipe = anytrue([for e in entries : e.enable_vllm_recipe])
    }
  }

  # Per-endpoint S3 URI for the vLLM recipe env file written by weight-fetch.
  # Format: s3://{model_assets}/{prefix}/recipe_{precision}.env
  # Empty string when enable_vllm_recipe = false (launch.sh skips sourcing).
  recipe_env_s3_uri = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => v.enable_vllm_recipe ? "s3://${try(aws_s3_bucket.model_assets[0].bucket, "")}/${local.open_weight_s3_prefix[k]}/recipe_${v.vllm_precision}.env" : null
  }
}

# --- Additional scripts URI resolution ---
#
# Resolves each script's source to a final S3 URI:
#   local path → s3://{codebuild_bucket}/additional-scripts/{md5}/{basename}
#   s3:// URI  → pass through unchanged
#
# Returns a newline-joined string for SageMaker (ADDITIONAL_SCRIPTS env var in launch.sh)
# and a list of strings for EKS (one init container per entry in deploy-nim.yml).
locals {
  local_script_s3_uri = {
    for path in local.all_local_additional_scripts :
    path => "s3://${aws_s3_bucket.codebuild.bucket}/additional-scripts/${filemd5(path)}/${basename(path)}"
  }

  additional_scripts_uris_sagemaker_nim = {
    for k, v in var.sagemaker_endpoints.nim :
    k => join("\n", [for s in v.additional_scripts : startswith(s.source, "s3://") ? s.source : local.local_script_s3_uri[s.source]])
  }

  additional_scripts_uris_sagemaker_ow = {
    for k, v in var.sagemaker_endpoints.open_weight :
    k => join("\n", [for s in v.additional_scripts : startswith(s.source, "s3://") ? s.source : local.local_script_s3_uri[s.source]])
  }

  additional_scripts_uris_eks_nim = {
    for k, v in var.eks_deployments.nim :
    k => [for s in v.additional_scripts : startswith(s.source, "s3://") ? s.source : local.local_script_s3_uri[s.source]]
  }

  additional_scripts_uris_eks_ow = {
    for k, v in var.eks_deployments.open_weight :
    k => [for s in v.additional_scripts : startswith(s.source, "s3://") ? s.source : local.local_script_s3_uri[s.source]]
  }
}

# --- SageMaker model container environments ---
#
# Defined here (not inline in main.tf) so random_id.model_content_suffix can key on
# them without referencing the model resource itself (which would be circular).
locals {
  nim_model_env = {
    for k, v in var.sagemaker_endpoints.nim : k => {
      NGC_API_KEY         = local.ngc_api_key
      HF_TOKEN            = local.hf_token
      CACHE_PATH          = var.cache_path
      MODEL_PROFILE_CACHE = v.enable_model_profile_cache ? "s3://${try(aws_s3_bucket.nim_cache[0].bucket, "")}/nim-cache/${local.uri_canonical[v.source_image_uri]}/${replace(v.instance_type, "ml.", "")}" : ""
      ADDITIONAL_SCRIPTS  = local.additional_scripts_uris_sagemaker_nim[k]
    }
  }

  open_weight_model_env = {
    for k, v in var.sagemaker_endpoints.open_weight : k => {
      NIM_CMD             = "vllm serve /opt/ml/model --port 8000 --served-model-name ${v.model_id}"
      NIM_HEALTH_PATH     = "/health"
      OPEN_WEIGHTS_S3_URI = "s3://${try(aws_s3_bucket.model_assets[0].bucket, "")}/${local.open_weight_s3_prefix[k]}"
      VLLM_USER_ARGS      = local.extra_args_str[k]
      RECIPE_ENV_S3_URI   = local.recipe_env_s3_uri[k]
      ADDITIONAL_SCRIPTS  = local.additional_scripts_uris_sagemaker_ow[k]
    }
  }
}
