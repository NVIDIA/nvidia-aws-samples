# ---------------------------------------------------------------------------
# SageMaker execution role
#
# AmazonSageMakerFullAccess does NOT include ECR pull permissions — an inline
# policy is required so the endpoint can pull the shim image from ECR.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_execution" {
  name               = "${local.name_prefix}-sagemaker-exec"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-sagemaker-exec"
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_full_access" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# ECR pull + explicit S3 access
#
# AmazonSageMakerFullAccess allows S3 only on bucket names matching *sagemaker*.
# Explicit grants here cover our nim-*-cache and nim-*-output buckets.
data "aws_iam_policy_document" "sagemaker_inline" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "ECRPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.nim.arn]
  }

  # Model profile cache — read (sync down at startup) and write (cache-profiles CodeBuild).
  # Only added when any endpoint has enable_model_profile_cache = true (bucket may not exist otherwise).
  dynamic "statement" {
    for_each = length(local.endpoints_with_cache) > 0 ? [1] : []
    content {
      sid = "S3CacheReadWrite"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.nim_cache[0].arn,
        "${aws_s3_bucket.nim_cache[0].arn}/*",
      ]
    }
  }

  # Model assets — open weight files synced from S3 by launch.sh at container startup.
  # Only added when any open weight endpoint is configured.
  dynamic "statement" {
    for_each = length(var.sagemaker_endpoints.open_weight) > 0 ? [1] : []
    content {
      sid = "S3ModelAssetsRead"
      actions = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.model_assets[0].arn,
        "${aws_s3_bucket.model_assets[0].arn}/*",
      ]
    }
  }

  # Async inference output — SageMaker writes response payloads here
  statement {
    sid = "S3OutputWrite"
    actions = [
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.sagemaker_output.arn,
      "${aws_s3_bucket.sagemaker_output.arn}/*",
    ]
  }

  # additional_scripts (local files) — uploaded to the module's codebuild bucket at
  # apply time (see archives.tf). shim/launch.sh `aws s3 cp`s each script before
  # Caddy + NIM start. Without this grant the runtime download returns 403.
  dynamic "statement" {
    for_each = local.sagemaker_has_additional_scripts ? [1] : []
    content {
      sid       = "S3AdditionalScriptsRead"
      actions   = ["s3:GetObject"]
      resources = ["${aws_s3_bucket.codebuild.arn}/additional-scripts/*"]
    }
  }

  # additional_scripts (external buckets) — when additional_scripts[].source is an
  # s3:// URI pointing outside the module's codebuild bucket, shim/launch.sh needs
  # read on that bucket. Buckets come from local.additional_scripts_external_buckets,
  # which unions URIs across all EKS + SageMaker deployments in this workspace.
  dynamic "statement" {
    for_each = local.sagemaker_has_additional_scripts && length(local.additional_scripts_external_buckets) > 0 ? [1] : []
    content {
      sid     = "S3ExternalScriptsRead"
      actions = ["s3:GetObject"]
      resources = [
        for b in local.additional_scripts_external_buckets : "arn:aws:s3:::${b}/*"
      ]
    }
  }
}

resource "aws_iam_role_policy" "sagemaker_inline" {
  name   = "${local.name_prefix}-sagemaker-inline"
  role   = aws_iam_role.sagemaker_execution.id
  policy = data.aws_iam_policy_document.sagemaker_inline.json
}

# ---------------------------------------------------------------------------
# CodeBuild role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${local.name_prefix}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-codebuild"
  })
}

data "aws_iam_policy_document" "codebuild_inline" {
  # ECR — GetAuthorizationToken is account-wide; push/pull scope to the repo
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "ECRPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.nim.arn]
  }

  # Build bucket — read/write shim-source.zip
  statement {
    sid = "S3BuildReadWrite"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.codebuild.arn,
      "${aws_s3_bucket.codebuild.arn}/*",
    ]
  }

  # Model profile cache bucket — CodeBuild writes; SageMaker launch.sh reads at startup.
  # Only added when any endpoint has enable_model_profile_cache = true.
  dynamic "statement" {
    for_each = length(local.endpoints_with_cache) > 0 ? [1] : []
    content {
      sid = "S3CacheReadWrite"
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.nim_cache[0].arn,
        "${aws_s3_bucket.nim_cache[0].arn}/*",
      ]
    }
  }

  # Model assets — CodeBuild weight-fetch writes; launch.sh reads at startup.
  # Only added when any open weight endpoint or EKS open weight deployment is configured.
  dynamic "statement" {
    for_each = length(var.sagemaker_endpoints.open_weight) > 0 || length(var.eks_deployments.open_weight) > 0 ? [1] : []
    content {
      sid = "S3ModelAssetsReadWrite"
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.model_assets[0].arn,
        "${aws_s3_bucket.model_assets[0].arn}/*",
      ]
    }
  }

  # CloudWatch Logs — CodeBuild streams build output here.
  # Two resource patterns are required: log group ARN for CreateLogGroup,
  # and the :* suffix (log stream ARN) for CreateLogStream and PutLogEvents.
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/codebuild/*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/codebuild/*:*",
    ]
  }

  # CodeBuild self-introspection — needed by the polling script in shim and
  # asset-prebuild buildspecs to check base-sync project status
  statement {
    sid = "CodeBuildDescribe"
    actions = [
      "codebuild:ListBuildsForProject",
      "codebuild:BatchGetBuilds",
    ]
    resources = ["arn:aws:codebuild:${var.region}:${local.account_id}:project/${local.name_prefix}-*"]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${local.name_prefix}-codebuild-policy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_inline.json
}

# ---------------------------------------------------------------------------
# EKS IRSA — model assets read (open-weight init container weight sync)
#
# Mirrors the SageMaker execution role pattern: one policy per cluster that
# has at least one open-weight deployment, attached at root level so the
# count never depends on a known-after-apply resource attribute.
# ---------------------------------------------------------------------------

locals {
  eks_clusters_with_open_weight = toset([
    for k, v in var.eks_deployments.open_weight : v.cluster_key
  ])
}

data "aws_iam_policy_document" "nim_irsa_s3_model_assets" {
  count = length(var.eks_deployments.open_weight) > 0 ? 1 : 0

  statement {
    sid     = "S3ModelAssetsRead"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.model_assets[0].arn,
      "${aws_s3_bucket.model_assets[0].arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "nim_irsa_s3_model_assets" {
  for_each = local.eks_clusters_with_open_weight

  name   = "${local.name_prefix}-${each.key}-nim-irsa-s3-assets"
  role   = module.eks_infra[each.key].nim_irsa_role_name
  policy = data.aws_iam_policy_document.nim_irsa_s3_model_assets[0].json
}

# ---------------------------------------------------------------------------
# EKS IRSA — additional_scripts read on the module's codebuild bucket
#
# Local files referenced by additional_scripts[].source are uploaded to
# the codebuild bucket at apply time (see archives.tf). At runtime the
# init container does `aws s3 cp` from that bucket — which requires the
# NIM IRSA role to have s3:GetObject on the codebuild bucket. Without
# this policy the init container exits 403.
# ---------------------------------------------------------------------------

locals {
  eks_clusters_with_additional_scripts = toset([
    for k, v in merge(
      { for k, v in var.eks_deployments.nim : k => v if length(v.additional_scripts) > 0 },
      { for k, v in var.eks_deployments.open_weight : k => v if length(v.additional_scripts) > 0 },
    ) : v.cluster_key
  ])
}

data "aws_iam_policy_document" "nim_irsa_s3_additional_scripts" {
  count = length(local.eks_clusters_with_additional_scripts) > 0 ? 1 : 0

  statement {
    sid       = "S3AdditionalScriptsRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.codebuild.arn}/additional-scripts/*"]
  }
}

resource "aws_iam_role_policy" "nim_irsa_s3_additional_scripts" {
  for_each = local.eks_clusters_with_additional_scripts

  name   = "${local.name_prefix}-${each.key}-nim-irsa-s3-add-scripts"
  role   = module.eks_infra[each.key].nim_irsa_role_name
  policy = data.aws_iam_policy_document.nim_irsa_s3_additional_scripts[0].json
}

# ---------------------------------------------------------------------------
# EKS IRSA — read access on external S3 buckets referenced by additional_scripts
#
# When additional_scripts[].source is an s3:// URI pointing OUTSIDE the
# module's own codebuild bucket, the runtime init container has no IRSA
# permission on that bucket and `aws s3 cp` returns 403.
#
# This block parses every s3:// URI across all eks_deployments, extracts
# the unique set of external buckets (excluding the codebuild bucket which
# has its own policy above), and grants s3:GetObject on each.
#
# Scope is intentionally bucket-wide rather than key-prefix-wide — the
# customer chose to keep the script at an arbitrary key under their bucket.
# ---------------------------------------------------------------------------

locals {
  # Extract bucket names from every s3:// URI in additional_scripts across both nim
  # and open_weight deployments on both EKS and SageMaker. Customers can't reference
  # the module's own codebuild bucket (its name has a random suffix not known until
  # apply), so any s3:// URI they supply is by definition an external bucket — no
  # need to filter.
  # Single union across platforms keeps the IAM concise; an EKS-only bucket may get
  # granted to the SageMaker exec role (or vice-versa) when the customer mixes
  # additional_scripts across platforms in the same workspace — harmless over-grant
  # bounded to buckets the customer explicitly referenced.
  additional_scripts_external_buckets = toset([
    for s in flatten([
      for v in concat(
        values(var.eks_deployments.nim),
        values(var.eks_deployments.open_weight),
        values(var.sagemaker_endpoints.nim),
        values(var.sagemaker_endpoints.open_weight),
      ) : v.additional_scripts
    ]) :
    regex("^s3://([^/]+)/", s.source)[0]
    if startswith(s.source, "s3://")
  ])

  # True when any SageMaker endpoint (nim or open_weight) has additional_scripts.
  # Gates the S3 statements added to the SageMaker execution role's inline policy.
  sagemaker_has_additional_scripts = length(merge(
    { for k, v in var.sagemaker_endpoints.nim : k => v if length(v.additional_scripts) > 0 },
    { for k, v in var.sagemaker_endpoints.open_weight : k => v if length(v.additional_scripts) > 0 },
  )) > 0
}

data "aws_iam_policy_document" "nim_irsa_s3_external_scripts" {
  count = length(local.additional_scripts_external_buckets) > 0 ? 1 : 0

  statement {
    sid     = "S3ExternalScriptsRead"
    actions = ["s3:GetObject"]
    resources = [
      for b in local.additional_scripts_external_buckets : "arn:aws:s3:::${b}/*"
    ]
  }
}

resource "aws_iam_role_policy" "nim_irsa_s3_external_scripts" {
  for_each = length(local.additional_scripts_external_buckets) > 0 ? local.eks_clusters_with_additional_scripts : []

  name   = "${local.name_prefix}-${each.key}-nim-irsa-s3-ext-scripts"
  role   = module.eks_infra[each.key].nim_irsa_role_name
  policy = data.aws_iam_policy_document.nim_irsa_s3_external_scripts[0].json
}
