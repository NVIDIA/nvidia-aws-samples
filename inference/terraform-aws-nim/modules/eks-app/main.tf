# ---------------------------------------------------------------------------
# modules/eks-app — per-deployment CodeBuild action trigger for EKS
#
# Handles two paths, selected by whether model_id is set:
#   NIM path (model_id = null): Helm install from NGC registry. The deploy
#     buildspec polls for the GPU NodePool, then runs helm upgrade --install.
#     Optional init container syncs NGC model profile cache from S3.
#   Open-weight path (model_id set): kubectl apply of a Deployment + Service.
#     An init container syncs HuggingFace weights from S3; the main container
#     runs vllm serve against the local weight directory.
#
# Outputs release_name and namespace for use in invoke commands.
# ---------------------------------------------------------------------------

locals {
  release_name = var.name_prefix
}

# ---------------------------------------------------------------------------
# Destroy-time Helm/namespace cleanup
#
# The NIM LoadBalancer Service provisions an NLB via the EKS LB controller.
# That NLB is NOT a Terraform resource — Terraform will not delete it on destroy.
# If the NLB still exists when the VPC is destroyed, the destroy fails with
# "DependencyViolation: the specified subnet has dependencies".
#
# This resource runs `helm uninstall` + `kubectl delete namespace` on destroy,
# which signals the LB controller to delete the NLB before the cluster is torn
# down. The EKS cluster (in eks-infra) is only destroyed after this module is
# fully destroyed, because module.eks_app depends_on module.eks_infra in the
# root module.
#
# on_failure = continue: if the cluster is already gone (e.g. manual deletion)
# we still want the Terraform destroy to complete cleanly.
# Requires aws, kubectl, and helm in PATH on the machine running Terraform.
# ---------------------------------------------------------------------------

resource "terraform_data" "helm_cleanup" {
  input = {
    cluster_name = var.cluster_name
    namespace    = var.namespace
    release_name = local.release_name
    region       = var.region
    model_id     = var.model_id != null ? var.model_id : ""
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      aws eks update-kubeconfig \
        --name "${self.input.cluster_name}" \
        --region "${self.input.region}" 2>/dev/null || true
      if [ -n "${self.input.model_id}" ]; then
        kubectl delete deployment "${self.input.release_name}" \
          --namespace "${self.input.namespace}" \
          --wait=true --timeout=5m 2>/dev/null || true
        kubectl delete service "${self.input.release_name}-svc" \
          --namespace "${self.input.namespace}" \
          --wait=true --timeout=5m 2>/dev/null || true
      else
        helm uninstall "${self.input.release_name}" \
          --namespace "${self.input.namespace}" \
          --wait --timeout 10m 2>/dev/null || true
      fi
      kubectl delete namespace "${self.input.namespace}" \
        --wait=true --timeout=5m 2>/dev/null || true
    EOT
  }
}

# ---------------------------------------------------------------------------
# EKS access entry for the deploy CodeBuild role
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "codebuild_deploy" {
  region        = var.region
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.codebuild_deploy.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "codebuild_deploy" {
  region        = var.region
  cluster_name  = var.cluster_name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.codebuild_deploy.arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.codebuild_deploy]
}

# ---------------------------------------------------------------------------
# CodeBuild project — EKS deploy (NIM via Helm or open-weight via kubectl)
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "nim_deploy" {
  region        = var.region
  name          = "${var.name_prefix}-nim-deploy"
  description   = "Deploy ${local.release_name} to cluster ${var.cluster_name} (${var.model_id != null ? "open-weight vLLM" : "NIM Helm"})"
  service_role  = aws_iam_role.codebuild_deploy.arn
  build_timeout = 90

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "CLUSTER_NAME"
      value = var.cluster_name
    }
    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }
    environment_variable {
      name  = "RELEASE_NAME"
      value = local.release_name
    }
    environment_variable {
      name  = "NAMESPACE"
      value = var.namespace
    }
    environment_variable {
      name  = "ECR_IMAGE_REPOSITORY"
      value = var.ecr_repository_url
    }
    environment_variable {
      name  = "ECR_IMAGE_TAG"
      value = var.ecr_image_tag != null ? var.ecr_image_tag : ""
    }
    environment_variable {
      name  = "MODEL_ID"
      value = var.model_id != null ? var.model_id : ""
    }
    environment_variable {
      name  = "MODEL_ASSETS_BUCKET"
      value = var.model_assets_bucket != null ? var.model_assets_bucket : ""
    }
    environment_variable {
      name  = "WEIGHTS_S3_PREFIX"
      value = var.weights_s3_prefix != null ? var.weights_s3_prefix : ""
    }
    environment_variable {
      name  = "EXTRA_ARGS"
      value = var.extra_args_str != null ? var.extra_args_str : ""
    }
    environment_variable {
      name  = "NIM_IRSA_ROLE_ARN"
      value = var.nim_irsa_role_arn
    }
    environment_variable {
      name  = "ENABLE_MODEL_PROFILE_CACHE"
      value = tostring(var.enable_model_profile_cache)
    }
    environment_variable {
      name  = "CACHE_BUCKET"
      value = var.cache_bucket != null ? var.cache_bucket : ""
    }
    environment_variable {
      name  = "CACHE_PREFIX"
      value = var.cache_prefix != null ? var.cache_prefix : ""
    }
    environment_variable {
      name  = "HELM_CHART_NAME"
      value = var.helm_chart_name != null ? var.helm_chart_name : ""
    }
    environment_variable {
      name  = "HELM_CHART_REPO_URL"
      value = var.helm_chart_repo_url != null ? var.helm_chart_repo_url : ""
    }
    environment_variable {
      name  = "HELM_CHART_VERSION"
      value = var.helm_chart_version != null ? var.helm_chart_version : ""
    }
    environment_variable {
      name  = "HELM_CHART_S3_URI"
      value = var.helm_chart_s3_uri != null ? var.helm_chart_s3_uri : ""
    }
    environment_variable {
      name  = "NIM_TYPE"
      value = var.nim_type != null ? var.nim_type : ""
    }
    environment_variable {
      name  = "PROTOCOL"
      value = var.protocol
    }
    environment_variable {
      name  = "PORT"
      value = tostring(var.port)
    }
    environment_variable {
      name  = "HELM_VALUES_OVERRIDE"
      value = var.helm_values_override != null ? var.helm_values_override : ""
    }
    environment_variable {
      name  = "GPU_COUNT"
      value = tostring(var.gpu_count)
    }
    environment_variable {
      name  = "REPLICAS"
      value = tostring(var.replicas)
    }
    environment_variable {
      name  = "NODE_POOL_NAME"
      value = var.node_pool_name
    }
    environment_variable {
      name  = "LOAD_BALANCER_INTERNAL"
      value = tostring(var.load_balancer_internal)
    }
    # Comma-separated for the buildspec to split. Empty string when null so the
    # buildspec's `[ -z ... ]` check skips emitting loadBalancerSourceRanges.
    environment_variable {
      name  = "NLB_ALLOWED_CIDR_BLOCKS"
      value = var.nlb_allowed_cidr_blocks != null ? join(",", var.nlb_allowed_cidr_blocks) : ""
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(var.debug)
    }
    environment_variable {
      name  = "ADDITIONAL_SCRIPTS"
      value = join("\n", var.additional_scripts)
    }
    # Autoscaling — empty strings when disabled so the buildspec's
    # `if [ "$AUTOSCALING_ENABLED" = "true" ]` check reads them safely.
    environment_variable {
      name  = "AUTOSCALING_ENABLED"
      value = tostring(var.autoscaling != null)
    }
    environment_variable {
      name  = "AUTOSCALING_MIN_REPLICAS"
      value = var.autoscaling != null ? tostring(var.autoscaling.min_replicas) : ""
    }
    environment_variable {
      name  = "AUTOSCALING_MAX_REPLICAS"
      value = var.autoscaling != null ? tostring(var.autoscaling.max_replicas) : ""
    }
    environment_variable {
      name  = "AUTOSCALING_METRIC"
      value = var.autoscaling != null ? var.autoscaling.metric : ""
    }
    environment_variable {
      name  = "AUTOSCALING_TARGET_VALUE"
      value = var.autoscaling != null ? tostring(var.autoscaling.target_value) : ""
    }
    environment_variable {
      name  = "AUTOSCALING_SCALE_DOWN_DELAY"
      value = var.autoscaling != null ? tostring(var.autoscaling.scale_down_delay) : ""
    }
    dynamic "environment_variable" {
      for_each = var.ngc_cb_env_value != null ? [1] : []
      content {
        name  = "NGC_API_KEY"
        value = var.ngc_cb_env_value
        type  = var.ngc_cb_env_type
      }
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [var.cluster_security_group_id]
  }

  source {
    type      = "NO_SOURCE"
    buildspec = var.buildspec_s3_arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-nim-deploy" })

  depends_on = [time_sleep.codebuild_deploy_iam_propagation]
}

# ---------------------------------------------------------------------------
# Action trigger — fires deploy on create/update
# ---------------------------------------------------------------------------

action "aws_codebuild_start_build" "nim_deploy" {
  config {
    region       = var.region
    project_name = aws_codebuild_project.nim_deploy.name
    timeout      = 5400
  }
}

resource "terraform_data" "deploy_trigger" {
  input = merge(
    {
      cluster_name               = var.cluster_name
      ecr_image_tag              = var.ecr_image_tag != null ? var.ecr_image_tag : ""
      model_id                   = var.model_id != null ? var.model_id : ""
      weights_s3_prefix          = var.weights_s3_prefix != null ? var.weights_s3_prefix : ""
      extra_args_str             = var.extra_args_str != null ? var.extra_args_str : ""
      enable_model_profile_cache = var.enable_model_profile_cache
      cache_prefix               = var.cache_prefix != null ? var.cache_prefix : ""
      nim_type                   = var.nim_type
      protocol                   = var.protocol
      port                       = var.port
      helm_chart_name            = var.helm_chart_name != null ? var.helm_chart_name : ""
      helm_chart_repo_url        = var.helm_chart_repo_url != null ? var.helm_chart_repo_url : ""
      helm_chart_version         = var.helm_chart_version != null ? var.helm_chart_version : ""
      helm_chart_s3_uri          = var.helm_chart_s3_uri != null ? var.helm_chart_s3_uri : ""
      helm_values_override       = var.helm_values_override != null ? var.helm_values_override : ""
      gpu_count                  = var.gpu_count
      replicas                   = var.replicas
      load_balancer_internal     = var.load_balancer_internal
      nlb_allowed_cidr_blocks    = var.nlb_allowed_cidr_blocks != null ? join(",", var.nlb_allowed_cidr_blocks) : ""
      autoscaling_enabled        = var.autoscaling != null
      autoscaling_min_replicas   = var.autoscaling != null ? var.autoscaling.min_replicas : 0
      autoscaling_max_replicas   = var.autoscaling != null ? var.autoscaling.max_replicas : 0
      autoscaling_metric         = var.autoscaling != null ? var.autoscaling.metric : ""
      autoscaling_target_value   = var.autoscaling != null ? var.autoscaling.target_value : 0
      autoscaling_scale_down     = var.autoscaling != null ? var.autoscaling.scale_down_delay : 0
      buildspec_hash             = filemd5("${path.module}/buildspecs/deploy-nim.yml")
    },
    var.force_rebuild ? { force_timestamp = timestamp() } : {}
  )

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.nim_deploy]
    }
  }

  depends_on = [
    aws_eks_access_policy_association.codebuild_deploy,
    aws_codebuild_project.nim_deploy,
  ]
}
