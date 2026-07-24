# ---------------------------------------------------------------------------
# main.tf — Core compute resources
#
# Contains: SageMaker model + endpoint config + endpoint (for_each on
#           sagemaker_endpoints), cross-variable validation preconditions.
#
# No provider block — consumers pass the AWS provider. Each resource sets
# region = var.region per the AWS provider v6 child-module pattern.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cross-variable validation preconditions
#
# Terraform variable validation blocks can only reference their own variable.
# Cross-variable constraints live here as preconditions on a sentinel resource.
# ---------------------------------------------------------------------------

resource "terraform_data" "validation" {
  lifecycle {
    # If any endpoint uses nvcr.io, NGC credentials must be present.
    precondition {
      condition     = local.ngc_configured || !local.any_ngc_endpoint
      error_message = "At least one endpoint uses an nvcr.io source image but no NGC API key is configured. Set ngc_credentials.api_key or ngc_credentials.secret_arn."
    }

    # model_profile requires enable_model_profile_cache = true per endpoint.
    precondition {
      condition = alltrue([
        for k, v in var.sagemaker_endpoints.nim :
        v.model_profile == null || v.enable_model_profile_cache
      ])
      error_message = "model_profile requires enable_model_profile_cache = true for the same endpoint entry."
    }

    # Each eks_deployment.cluster_key must match a key in eks_clusters.
    precondition {
      condition = alltrue([
        for k, v in merge(var.eks_deployments.nim, var.eks_deployments.open_weight) : contains(keys(var.eks_clusters), v.cluster_key)
      ])
      error_message = "One or more eks_deployments entries have a cluster_key that does not match any key in eks_clusters. The cluster_key must exactly match the eks_clusters map key."
    }

    # A deployment with autoscaling configured requires its target cluster to have
    # enable_autoscaling = true (KEDA/Prometheus/DCGM must be installed on the cluster
    # before any ScaledObject can be scheduled against it).
    precondition {
      condition = alltrue([
        for k, v in merge(var.eks_deployments.nim, var.eks_deployments.open_weight) :
        v.autoscaling == null || var.eks_clusters[v.cluster_key].enable_autoscaling
      ])
      error_message = "One or more eks_deployments entries set `autoscaling` but their target cluster does not have `enable_autoscaling = true`. Enable autoscaling on the cluster first."
    }

    # Future PR: restore enable_asset_build precondition when re-enabling custom build path.
  }
}


# ---------------------------------------------------------------------------
# SageMaker Endpoint CloudWatch Log Groups
#
# Pre-created so Terraform owns the lifecycle: retention policy is applied before
# SageMaker writes any logs, and force_destroy = true allows cleanup on destroy.
# SageMaker always writes to /aws/sagemaker/Endpoints/{endpoint-name} — pre-creating
# that exact group intercepts it rather than redirecting it.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "sagemaker_endpoint_nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.nim

  region            = var.region
  name              = "/aws/sagemaker/Endpoints/${local.sagemaker_endpoint_names_nim[each.key]}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/aws/sagemaker/Endpoints/${local.sagemaker_endpoint_names_nim[each.key]}"
  })
}

resource "aws_cloudwatch_log_group" "sagemaker_endpoint_ow" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.open_weight

  region            = var.region
  name              = "/aws/sagemaker/Endpoints/${local.sagemaker_endpoint_names_ow[each.key]}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/aws/sagemaker/Endpoints/${local.sagemaker_endpoint_names_ow[each.key]}"
  })
}

# ---------------------------------------------------------------------------
# SageMaker Model
#
# for_each over var.sagemaker_endpoints — one model per map entry.
# Empty map = no SageMaker resources (DDC pattern).
#
# ECR image: ECR:"{canonical}-shim" — one shim per unique source_image_uri.
# Endpoints sharing the same source_image_uri share the same shim image.
#
# enable_network_isolation = false is MANDATORY.
# NIM downloads weights and validates its license against NVIDIA's servers at
# startup. Network isolation blocks both.
#
# MODEL_PROFILE_CACHE: s3://<cache_bucket>/nim-cache/<key>/ — per-endpoint prefix.
# launch.sh syncs this into CACHE_PATH at startup. Empty when caching is disabled.
# try() guards the nim_cache bucket reference (count = 0 when no caching enabled).
# ---------------------------------------------------------------------------

resource "aws_sagemaker_model" "nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.nim

  region = var.region

  name               = local.sagemaker_model_names_nim[each.key]
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    image       = "${aws_ecr_repository.nim.repository_url}:${local.endpoint_to_shim_tag[each.key]}"
    mode        = "SingleModel"
    environment = local.nim_model_env[each.key]
  }

  enable_network_isolation = false

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = local.sagemaker_model_names_nim[each.key]
  })

  depends_on = [
    terraform_data.build_trigger_shim,
    terraform_data.build_trigger_model_profile_cache,
  ]
}

resource "aws_sagemaker_model" "open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.open_weight

  region = var.region

  name               = local.sagemaker_model_names_ow[each.key]
  execution_role_arn = aws_iam_role.sagemaker_execution.arn

  primary_container {
    image       = "${aws_ecr_repository.nim.repository_url}:${local.open_weight_endpoint_to_shim_tag[each.key]}"
    mode        = "SingleModel"
    environment = local.open_weight_model_env[each.key]
  }

  enable_network_isolation = false

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = local.sagemaker_model_names_ow[each.key]
  })

  depends_on = [
    terraform_data.build_trigger_shim,
    terraform_data.build_trigger_weight_fetch,
  ]
}

# ---------------------------------------------------------------------------
# SageMaker Endpoint Configuration
#
# Async inference is required for Alpamayo — a single request contains
# 16 base64-encoded camera frames (~50 MB), exceeding SageMaker's 6 MB
# synchronous body limit.
#
# Async output path is namespaced by endpoint key:
#   s3://<output_bucket>/<key>/<async_output_s3_prefix>
#
# Split into .nim and .open_weight so each resource iterates a typed map and
# accesses only the fields that exist on that schema — no try() needed.
# ---------------------------------------------------------------------------

resource "aws_sagemaker_endpoint_configuration" "nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.nim

  region = var.region

  # Includes random_id.endpoint_config_suffix_nim so the name rotates when model content
  # changes. A new name here causes aws_sagemaker_endpoint to issue UpdateEndpoint
  # (blue-green, no endpoint ARN change) rather than destroy+create.
  name = "${local.sagemaker_endpoint_names_nim[each.key]}-${random_id.endpoint_config_suffix_nim[each.key].hex}-cfg"

  lifecycle {
    create_before_destroy = true
  }

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.nim[each.key].name
    instance_type          = each.value.instance_type
    initial_instance_count = 1
    initial_variant_weight = 1.0

    container_startup_health_check_timeout_in_seconds = each.value.container_startup_timeout

    # Null omits the field — correct for g6e and p5 where the default AMI is adequate.
    inference_ami_version = each.value.inference_ami_version

    # ml_reservation_arn wiring: the hashicorp/aws provider does not expose
    # capacity_reservation_config in production_variants (no open issue as of 2026-04).
    # When ml_reservation_arn is set, use the AWSCC path below instead of this resource.
    # Tracking: file https://github.com/hashicorp/terraform-provider-aws/issues/new
    # requesting capacity_reservation_config in aws_sagemaker_endpoint_configuration.
    #
    # What it would look like once the provider adds support:
    # dynamic "capacity_reservation_config" {
    #   for_each = each.value.ml_reservation_arn != null ? [1] : []
    #   content {
    #     capacity_reservation_preference = "capacity-reservations-only"
    #     ml_reservation_arn              = each.value.ml_reservation_arn
    #   }
    # }
  }

  # dynamic renders this block once ([1]) or not at all ([]). count can't gate blocks inside a resource, only dynamic can.
  dynamic "async_inference_config" {
    for_each = each.value.endpoint_type == "async" ? [1] : []
    content {
      output_config {
        s3_output_path = "s3://${aws_s3_bucket.sagemaker_output.bucket}/${each.key}/${each.value.async_output_s3_prefix}"
      }
    }
  }

  tags = merge(var.tags, {
    Name = "${local.sagemaker_endpoint_names_nim[each.key]}-${random_id.endpoint_config_suffix_nim[each.key].hex}-cfg"
  })
}

resource "aws_sagemaker_endpoint_configuration" "open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.open_weight

  region = var.region

  name = "${local.sagemaker_endpoint_names_ow[each.key]}-${random_id.endpoint_config_suffix_open_weight[each.key].hex}-cfg"

  lifecycle {
    create_before_destroy = true
  }

  production_variants {
    variant_name           = "AllTraffic"
    model_name             = aws_sagemaker_model.open_weight[each.key].name
    instance_type          = each.value.instance_type
    initial_instance_count = 1
    initial_variant_weight = 1.0

    container_startup_health_check_timeout_in_seconds = each.value.container_startup_timeout

    inference_ami_version = each.value.inference_ami_version
  }

  # dynamic renders this block once ([1]) or not at all ([]). count can't gate blocks inside a resource, only dynamic can.
  dynamic "async_inference_config" {
    for_each = each.value.endpoint_type == "async" ? [1] : []
    content {
      output_config {
        s3_output_path = "s3://${aws_s3_bucket.sagemaker_output.bucket}/${each.key}/${each.value.async_output_s3_prefix}"
      }
    }
  }

  tags = merge(var.tags, {
    Name = "${local.sagemaker_endpoint_names_ow[each.key]}-${random_id.endpoint_config_suffix_open_weight[each.key].hex}-cfg"
  })
}

# ---------------------------------------------------------------------------
# SageMaker Endpoint
#
# Terraform waits up to 90 minutes for InService. On first deploy without a warm
# S3 asset cache, this covers the full TRT build (45-90 min). With a warm cache
# the endpoint typically reaches InService in ~5-7 min.
#
# random_id suffix: SageMaker deletion is async — the name is held during the
# "Deleting" state. A random suffix ensures destroy+apply always uses a new name,
# avoiding "Cannot create already existing endpoint" errors.
# ---------------------------------------------------------------------------

resource "random_id" "endpoint_suffix_nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.nim
  byte_length = 4
}

resource "random_id" "endpoint_suffix_ow" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.open_weight
  byte_length = 4
}

# Rotates when NIM model image or environment changes. Model names include this suffix so
# the new model gets a different name from the old one, letting create_before_destroy
# work without hitting SageMaker's "already exists" error during async deletion.
resource "random_id" "model_content_suffix_nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.nim
  byte_length = 2

  keepers = {
    image       = "${aws_ecr_repository.nim.repository_url}:${local.endpoint_to_shim_tag[each.key]}"
    environment = jsonencode(local.nim_model_env[each.key])
  }
}

resource "random_id" "model_content_suffix_open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.open_weight
  byte_length = 2

  keepers = {
    image       = "${aws_ecr_repository.nim.repository_url}:${local.open_weight_endpoint_to_shim_tag[each.key]}"
    environment = jsonencode(local.open_weight_model_env[each.key])
  }
}

# Rotates when model_content_suffix rotates. A new config name triggers SageMaker
# UpdateEndpoint (blue-green) rather than endpoint destroy+create.
# create_before_destroy ensures the old config still exists when UpdateEndpoint fires —
# SageMaker requires this for the blue-green transition.
resource "random_id" "endpoint_config_suffix_nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.nim
  byte_length = 2

  keepers = {
    model_suffix = random_id.model_content_suffix_nim[each.key].hex
  }
}

resource "random_id" "endpoint_config_suffix_open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each    = var.sagemaker_endpoints.open_weight
  byte_length = 2

  keepers = {
    model_suffix = random_id.model_content_suffix_open_weight[each.key].hex
  }
}

resource "aws_sagemaker_endpoint" "nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.nim

  region = var.region

  name                 = local.sagemaker_endpoint_names_nim[each.key]
  endpoint_config_name = aws_sagemaker_endpoint_configuration.nim[each.key].name

  tags = merge(var.tags, {
    Name = local.sagemaker_endpoint_names_nim[each.key]
  })
}

resource "aws_sagemaker_endpoint" "open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.sagemaker_endpoints.open_weight

  region = var.region

  name                 = local.sagemaker_endpoint_names_ow[each.key]
  endpoint_config_name = aws_sagemaker_endpoint_configuration.open_weight[each.key].name

  tags = merge(var.tags, {
    Name = local.sagemaker_endpoint_names_ow[each.key]
  })
}

# ---------------------------------------------------------------------------
# EKS: infra submodule (one per eks_clusters entry)
#
# Provisions the EKS Auto Mode cluster, IAM, SG, OIDC provider, NIM IRSA role,
# and a cluster-setup CodeBuild action that creates the GPU NodePool.
# ---------------------------------------------------------------------------

module "eks_infra" {
  for_each = var.eks_clusters
  source   = "./modules/eks-infra"

  name_prefix             = "${local.name_prefix}-${each.key}"
  region                  = var.region
  tags                    = var.tags
  vpc_id                  = each.value.vpc_id
  private_subnet_ids      = each.value.private_subnet_ids
  public_subnet_ids       = each.value.public_subnet_ids
  instance_type           = each.value.instance_type
  kubernetes_version      = each.value.kubernetes_version
  cache_bucket_arn        = local.cluster_has_cache[each.key] ? aws_s3_bucket.nim_cache[0].arn : null
  enable_cache_iam        = local.cluster_has_cache[each.key]
  endpoint_public_access  = each.value.endpoint_public_access
  endpoint_private_access = each.value.endpoint_private_access
  public_access_cidrs     = each.value.public_access_cidrs
  allowed_cidr_blocks     = each.value.allowed_cidr_blocks
  internet_gateway_id     = each.value.internet_gateway_id
  cluster_log_types       = each.value.cluster_log_types
  eks_access_entries      = each.value.eks_access_entries
  enable_autoscaling      = each.value.enable_autoscaling
  buildspec_s3_arn        = "arn:aws:s3:::${aws_s3_bucket.codebuild.id}/${aws_s3_object.cluster_setup_buildspec[0].key}"
  buildspec_s3_bucket     = aws_s3_bucket.codebuild.id
  buildspec_s3_key        = aws_s3_object.cluster_setup_buildspec[0].key
  debug                   = var.debug || each.value.debug
  force_rebuild           = var.force_rebuild || each.value.force_rebuild
}

# ---------------------------------------------------------------------------
# EKS: app submodule — NIM path (Helm + NGC container image)
#
# Split from open_weight so each module call iterates a typed map and passes
# nim-specific fields (helm_chart_*, nim_type, ecr_image_tag) directly.
# ---------------------------------------------------------------------------

module "eks_app_nim" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.eks_deployments.nim
  source   = "./modules/eks-app"

  name_prefix                = "${local.name_prefix}-${each.key}-nim"
  region                     = var.region
  tags                       = var.tags
  cluster_name               = module.eks_infra[each.value.cluster_key].cluster_name
  cluster_security_group_id  = module.eks_infra[each.value.cluster_key].cluster_security_group_id
  vpc_id                     = module.eks_infra[each.value.cluster_key].vpc_id
  private_subnet_ids         = module.eks_infra[each.value.cluster_key].private_subnet_ids
  nim_irsa_role_arn          = module.eks_infra[each.value.cluster_key].nim_irsa_role_arn
  ecr_repository_url         = aws_ecr_repository.nim.repository_url
  ecr_image_tag              = local.uri_base_tag[each.value.source_image_uri]
  model_id                   = null
  model_assets_bucket        = null
  weights_s3_prefix          = null
  extra_args_str             = null
  ngc_api_key                = local.ngc_api_key
  ngc_cb_env_value           = local.ngc_cb_env_value
  ngc_cb_env_type            = local.ngc_cb_env_type
  ngc_secret_arn             = try(var.ngc_credentials.secret_arn, null)
  enable_model_profile_cache = each.value.enable_model_profile_cache
  cache_bucket               = each.value.enable_model_profile_cache ? aws_s3_bucket.nim_cache[0].bucket : null
  cache_prefix               = each.value.enable_model_profile_cache ? local.eks_cache_prefix[each.key] : null
  nim_type                   = each.value.nim_type
  helm_chart_name            = local.eks_helm_chart_name[each.key]
  helm_chart_repo_url        = local.eks_helm_chart_repo_url[each.key]
  helm_chart_version         = each.value.helm_chart_version
  helm_chart_s3_uri          = each.value.helm_chart_s3_uri
  helm_values_override       = each.value.helm_values_override
  gpu_count                  = local.eks_nim_gpu_count[each.key]
  replicas                   = each.value.replicas
  namespace                  = coalesce(each.value.namespace, each.key)
  node_pool_name             = "${local.name_prefix}-${each.value.cluster_key}-gpu"
  load_balancer_internal     = each.value.load_balancer_internal
  nlb_allowed_cidr_blocks    = each.value.nlb_allowed_cidr_blocks
  debug                      = var.debug || each.value.debug
  force_rebuild              = var.force_rebuild || each.value.force_rebuild
  additional_scripts         = local.additional_scripts_uris_eks_nim[each.key]
  protocol                   = each.value.protocol
  port                       = local.eks_nim_resolved_port[each.key]
  autoscaling                = local.eks_nim_autoscaling_resolved[each.key]
  buildspec_s3_arn           = "arn:aws:s3:::${aws_s3_bucket.codebuild.id}/${aws_s3_object.deploy_nim_buildspec[0].key}"
  buildspec_s3_bucket        = aws_s3_bucket.codebuild.id
  buildspec_s3_key           = aws_s3_object.deploy_nim_buildspec[0].key

  depends_on = [
    terraform_data.build_trigger_base_sync,
    module.eks_infra,
  ]
}

# ---------------------------------------------------------------------------
# EKS: app submodule — open-weight path (kubectl + vLLM)
#
# Split from nim so each module call iterates a typed map and passes
# open-weight-specific fields (model_id, weights_s3_prefix, extra_args_str) directly.
# ---------------------------------------------------------------------------

module "eks_app_open_weight" {
  # One resource per map entry. Empty map = nothing created. k = entry name, v = entry config.
  for_each = var.eks_deployments.open_weight
  source   = "./modules/eks-app"

  name_prefix                = "${local.name_prefix}-${each.key}-ow"
  region                     = var.region
  tags                       = var.tags
  cluster_name               = module.eks_infra[each.value.cluster_key].cluster_name
  cluster_security_group_id  = module.eks_infra[each.value.cluster_key].cluster_security_group_id
  vpc_id                     = module.eks_infra[each.value.cluster_key].vpc_id
  private_subnet_ids         = module.eks_infra[each.value.cluster_key].private_subnet_ids
  nim_irsa_role_arn          = module.eks_infra[each.value.cluster_key].nim_irsa_role_arn
  ecr_repository_url         = aws_ecr_repository.nim.repository_url
  ecr_image_tag              = null
  model_id                   = each.value.model_id
  model_assets_bucket        = local.any_weights_enabled ? aws_s3_bucket.model_assets[0].bucket : null
  weights_s3_prefix          = local.eks_open_weight_s3_prefix[each.key]
  extra_args_str             = local.eks_extra_args_str[each.key]
  ngc_api_key                = local.ngc_api_key
  ngc_cb_env_value           = local.ngc_cb_env_value
  ngc_cb_env_type            = local.ngc_cb_env_type
  ngc_secret_arn             = try(var.ngc_credentials.secret_arn, null)
  enable_model_profile_cache = false
  cache_bucket               = null
  cache_prefix               = null
  nim_type                   = null
  helm_chart_name            = null
  helm_chart_repo_url        = null
  helm_chart_version         = null
  helm_chart_s3_uri          = null
  helm_values_override       = null
  gpu_count                  = local.eks_ow_gpu_count[each.key]
  replicas                   = each.value.replicas
  namespace                  = coalesce(each.value.namespace, each.key)
  node_pool_name             = "${local.name_prefix}-${each.value.cluster_key}-gpu"
  load_balancer_internal     = each.value.load_balancer_internal
  nlb_allowed_cidr_blocks    = each.value.nlb_allowed_cidr_blocks
  debug                      = var.debug || each.value.debug
  force_rebuild              = var.force_rebuild || each.value.force_rebuild
  additional_scripts         = local.additional_scripts_uris_eks_ow[each.key]
  # Open-weight serves vLLM, which is HTTP-only on 8000. The protocol + port
  # variables exist on the eks-app module to support the NIM path; pass static
  # values here so the module has consistent inputs.
  protocol            = "http"
  port                = 8000
  autoscaling         = local.eks_ow_autoscaling_resolved[each.key]
  buildspec_s3_arn    = "arn:aws:s3:::${aws_s3_bucket.codebuild.id}/${aws_s3_object.deploy_nim_buildspec[0].key}"
  buildspec_s3_bucket = aws_s3_bucket.codebuild.id
  buildspec_s3_key    = aws_s3_object.deploy_nim_buildspec[0].key

  depends_on = [
    terraform_data.build_trigger_weight_fetch,
    module.eks_infra,
  ]
}
