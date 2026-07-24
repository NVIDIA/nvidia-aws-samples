# IAM propagation delay — CodeBuild hits AccessDenied if started too soon
# after the role is created. History: 30s → 60s → 120s. Each bump driven by an
# observed race where CloudWatch Logs' IAM-evaluation cache hadn't picked up
# the role's inline policy by the time the first CreateLogStream fired.
# A polling gate (simulate-principal-policy until Allow, or retry-on-AccessDenied
# in the action) would be the proper fix.
resource "time_sleep" "codebuild_iam_propagation" {
  create_duration = "120s"
  depends_on      = [aws_iam_role_policy.codebuild]
}


# - Base Sync -
# Pulls source_image_uri and pushes to ECR as {base_tag}.
# Handles both NGC (nvcr.io) and ECR source images.
resource "aws_codebuild_project" "base_sync" {
  for_each = local.base_sync_map

  region = var.region

  name          = "${local.name_prefix}-base-sync-${replace(each.key, ".", "-")}"
  description   = "Pulls ${each.value.source_image_uri} and pushes to ECR as ${each.value.base_tag}."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 120

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "SOURCE_IMAGE_URI"
      value = each.value.source_image_uri
    }
    environment_variable {
      name  = "BASE_TAG"
      value = each.value.base_tag
    }
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.nim.repository_url
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(each.value.debug)
    }
    dynamic "environment_variable" {
      for_each = can(regex("^nvcr\\.io/", each.value.source_image_uri)) && local.ngc_cb_env_value != null ? [1] : []
      content {
        name  = "NGC_API_KEY"
        value = local.ngc_cb_env_value
        type  = local.ngc_cb_env_type
      }
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspecs/base-sync.yml")
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-base-sync-${replace(each.key, ".", "-")}"
  })
}


# Shim Build
# NIM entries: one project per unique source_image_uri (ECR:base → ECR:shim).
# Open-weight entries: one project per unique framework (e.g. "ow--vllm"); builds
# FROM the public framework base image directly — no ECR base-sync step needed.
resource "aws_codebuild_project" "shim" {
  for_each = local.shim_map

  region = var.region

  name          = "${local.name_prefix}-shim-${replace(each.key, ".", "-")}"
  description   = "Builds SageMaker NIM shim image: ${each.value.base_tag} → ${each.value.shim_tag}."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 120

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "SOURCE_IMAGE_URI"
      value = each.value.source_image_uri
    }
    environment_variable {
      name  = "BASE_TAG"
      value = each.value.base_tag
    }
    environment_variable {
      name  = "SHIM_TAG"
      value = each.value.shim_tag
    }
    environment_variable {
      name  = "SYNC_TO_ECR"
      value = tostring(each.value.sync_to_ecr)
    }
    environment_variable {
      name  = "BASE_SYNC_PROJECT"
      value = each.value.base_sync_project
    }
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.nim.repository_url
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "NIM_CMD"
      value = each.value.nim_cmd
    }
    environment_variable {
      name  = "NIM_ENTRYPOINT"
      value = each.value.nim_entrypoint
    }
    environment_variable {
      name  = "CADDY_BACKEND_PORT"
      value = each.value.caddy_backend_port != null ? tostring(each.value.caddy_backend_port) : ""
    }
    environment_variable {
      name  = "CACHE_PATH"
      value = var.cache_path
    }
    environment_variable {
      name  = "CUDA_DRIVER_LABEL"
      value = each.value.cuda_driver_label != null ? each.value.cuda_driver_label : ""
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(each.value.debug)
    }
    environment_variable {
      name  = "FORCE_REBUILD"
      value = tostring(each.value.force_rebuild)
    }
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.codebuild.bucket}/codebuild-source/shim-source.zip"
    buildspec = file("${path.module}/buildspecs/shim.yml")
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-shim-${replace(each.key, ".", "-")}"
  })
}


# Weight Fetch - (one project per unique model_id × model_source × revision)
# Downloads open weight model files from HuggingFace or NGC to S3 model-assets bucket.
# Idempotent: skips if WEIGHTS_COMPLETE marker already present in S3 prefix.
resource "aws_codebuild_project" "weight_fetch" {
  for_each = local.weight_fetch_map

  region = var.region

  name          = "${local.name_prefix}-weight-fetch-${replace(each.key, ".", "-")}"
  description   = "Downloads ${each.value.model_id} (${each.value.model_source}) weights to S3."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 180

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "MODEL_ID"
      value = each.value.model_id
    }
    environment_variable {
      name  = "MODEL_SOURCE"
      value = each.value.model_source
    }
    environment_variable {
      name  = "MODEL_REVISION"
      value = each.value.model_revision
    }
    environment_variable {
      name  = "S3_BUCKET"
      value = local.any_weights_enabled ? aws_s3_bucket.model_assets[0].bucket : ""
    }
    environment_variable {
      name  = "S3_PREFIX"
      value = each.value.s3_prefix
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "FORCE_REBUILD"
      value = tostring(each.value.force_rebuild)
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(each.value.debug)
    }
    environment_variable {
      name  = "ENABLE_VLLM_RECIPE"
      value = tostring(each.value.enable_vllm_recipe)
    }
    dynamic "environment_variable" {
      for_each = local.hf_cb_env_value != null ? [1] : []
      content {
        name  = "HF_TOKEN"
        value = local.hf_cb_env_value
        type  = local.hf_cb_env_type
      }
    }
    dynamic "environment_variable" {
      for_each = local.ngc_cb_env_value != null && each.value.model_source == "ngc" ? [1] : []
      content {
        name  = "NGC_API_KEY"
        value = local.ngc_cb_env_value
        type  = local.ngc_cb_env_type
      }
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspecs/weight-fetch.yml")
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-weight-fetch-${replace(each.key, ".", "-")}"
  })
}

action "aws_codebuild_start_build" "weight_fetch" {
  for_each = local.weight_fetch_map
  config {
    project_name = aws_codebuild_project.weight_fetch[each.key].name
    timeout      = 7200
  }
}

resource "terraform_data" "build_trigger_weight_fetch" {
  for_each = local.weight_fetch_map

  input = jsonencode({
    config        = each.value
    rebuild_token = each.value.force_rebuild ? timestamp() : "stable"
  })

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.weight_fetch[each.key]]
    }
  }

  depends_on = [
    aws_codebuild_project.weight_fetch,
    aws_s3_bucket.model_assets,
    time_sleep.codebuild_iam_propagation,
  ]
}

# ---------------------------------------------------------------------------
# Model Profile Cache
# One project per unique (source_image_uri × instance_type) combo. CPU-only.
# Runs list-model-profiles → auto-selects the best NGC profile for the target
# instance type → downloads to S3. pre_build polls the paired base-sync project.
resource "aws_codebuild_project" "model_profile_cache" {
  for_each = local.cache_map

  region = var.region

  name          = "${local.name_prefix}-model-profile-cache-${each.key}"
  description   = "Downloads NGC model profile for ${each.value.source_image_uri} on ${each.value.instance_type} → S3."
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 120

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "SOURCE_IMAGE_URI"
      value = each.value.source_image_uri
    }
    environment_variable {
      name  = "BASE_TAG"
      value = each.value.base_tag
    }
    environment_variable {
      name  = "INSTANCE_TYPE"
      value = each.value.instance_type
    }
    environment_variable {
      name  = "MODEL_PROFILE"
      value = each.value.model_profile
    }
    environment_variable {
      name  = "CACHE_PREFIX"
      value = each.value.cache_prefix
    }
    environment_variable {
      name  = "SYNC_TO_ECR"
      value = tostring(each.value.sync_to_ecr)
    }
    environment_variable {
      name  = "BASE_SYNC_PROJECT"
      value = each.value.base_sync_project
    }
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.nim.repository_url
    }
    environment_variable {
      name  = "S3_BUCKET"
      value = local.any_cache_enabled ? aws_s3_bucket.nim_cache[0].bucket : ""
    }
    environment_variable {
      name  = "CACHE_PATH"
      value = var.cache_path
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(each.value.debug)
    }
    dynamic "environment_variable" {
      for_each = local.ngc_cb_env_value != null ? [1] : []
      content {
        name  = "NGC_API_KEY"
        value = local.ngc_cb_env_value
        type  = local.ngc_cb_env_type
      }
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/buildspecs/model-profile-cache.yml")
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-model-profile-cache-${each.key}"
  })
}


# - Terraform Actions — one action per project instance.
# for_each mirrors the project for_each so each action targets its own project.
action "aws_codebuild_start_build" "base_sync" {
  for_each = local.base_sync_map
  config {
    project_name = aws_codebuild_project.base_sync[each.key].name
    timeout      = 7200 # 2 hours — matches build_timeout; NIM image pulls can exceed 1 hour
  }
}

action "aws_codebuild_start_build" "shim" {
  for_each = local.shim_map
  config {
    project_name = aws_codebuild_project.shim[each.key].name
    timeout      = 3600
  }
}

action "aws_codebuild_start_build" "model_profile_cache" {
  for_each = local.cache_map
  config {
    project_name = aws_codebuild_project.model_profile_cache[each.key].name
    timeout      = 3600
  }
}


# - Build triggers — one terraform_data per project instance.
# Input changes drive re-runs; force_rebuild = true triggers on every apply.
resource "terraform_data" "build_trigger_base_sync" {
  for_each = local.base_sync_map

  input = jsonencode({
    config        = each.value
    rebuild_token = each.value.force_rebuild ? timestamp() : "stable"
  })

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.base_sync[each.key]]
    }
  }

  depends_on = [
    aws_codebuild_project.base_sync,
    time_sleep.codebuild_iam_propagation,
  ]
}

resource "terraform_data" "build_trigger_shim" {
  for_each = local.shim_map

  input = jsonencode({
    shim_hash     = data.archive_file.shim_source.output_md5
    config        = each.value
    rebuild_token = each.value.force_rebuild ? timestamp() : "stable"
  })

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.shim[each.key]]
    }
  }

  depends_on = [
    aws_s3_object.shim_source,
    aws_codebuild_project.shim,
    time_sleep.codebuild_iam_propagation,
  ]
}

resource "terraform_data" "build_trigger_model_profile_cache" {
  for_each = local.cache_map

  input = jsonencode({
    config        = each.value
    rebuild_token = each.value.force_rebuild ? timestamp() : "stable"
  })

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.model_profile_cache[each.key]]
    }
  }

  depends_on = [
    aws_codebuild_project.model_profile_cache,
    time_sleep.codebuild_iam_propagation,
  ]
}
