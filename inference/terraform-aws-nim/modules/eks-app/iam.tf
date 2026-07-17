# ---------------------------------------------------------------------------
# CodeBuild role for NIM helm deployment
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_deploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_deploy" {
  name               = "${var.name_prefix}-eks-deploy-cb"
  assume_role_policy = data.aws_iam_policy_document.codebuild_deploy_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-eks-deploy-cb" })
}

data "aws_iam_policy_document" "codebuild_deploy_policy" {
  statement {
    sid       = "EKSDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:*:cluster/${var.cluster_name}"]
  }

  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.region}:*:log-group:/aws/codebuild/*",
      "arn:aws:logs:${var.region}:*:log-group:/aws/codebuild/*:*",
    ]
  }

  statement {
    sid = "CodeBuildSelf"
    actions = [
      "codebuild:ListBuildsForProject",
      "codebuild:BatchGetBuilds",
    ]
    resources = ["arn:aws:codebuild:${var.region}:*:project/${var.name_prefix}-*"]
  }

  statement {
    sid       = "STS"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid = "VPC"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
      "ec2:CreateNetworkInterfacePermission",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.helm_chart_s3_uri != null ? [1] : []
    content {
      sid     = "CustomChartS3"
      actions = ["s3:GetObject"]
      resources = [
        "arn:aws:s3:::${split("/", trimprefix(var.helm_chart_s3_uri, "s3://"))[0]}/*"
      ]
    }
  }

  # CodeBuild reads the buildspec from S3 at build-time. Scoped tight.
  statement {
    sid       = "BuildspecRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.buildspec_s3_bucket}/${var.buildspec_s3_key}"]
  }
}

resource "aws_iam_role_policy" "codebuild_deploy" {
  name   = "${var.name_prefix}-eks-deploy-cb"
  role   = aws_iam_role.codebuild_deploy.id
  policy = data.aws_iam_policy_document.codebuild_deploy_policy.json
}

# IAM propagation delay — see codebuild.tf header for the 30s → 60s → 120s history and the
# polling-gate replacement that's the proper structural fix for this class of issue.
resource "time_sleep" "codebuild_deploy_iam_propagation" {
  create_duration = "120s"
  depends_on = [
    aws_iam_role.codebuild_deploy,
    aws_iam_role_policy.codebuild_deploy,
  ]
}
