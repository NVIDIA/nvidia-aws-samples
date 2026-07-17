# ---------------------------------------------------------------------------
# Cluster role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-eks-cluster" })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# AmazonEKSClusterPolicy grants logs:CreateLogGroup, which lets EKS recreate
# /aws/eks/<name>/cluster during control-plane shutdown — after Terraform has
# already deleted it, causing "already exists" on the next apply. This explicit
# DENY overrides the Allow so Terraform owns the log group exclusively.
resource "aws_iam_role_policy" "eks_cluster_deny_log_group_create" {
  name = "${var.name_prefix}-deny-log-group-create"
  role = aws_iam_role.eks_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = "logs:CreateLogGroup"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_compute_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSComputePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_block_storage_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_load_balancing_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_networking_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
}

# ---------------------------------------------------------------------------
# Node role (used by EKS Auto Mode nodes)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com", "eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.name_prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-eks-node" })
}

resource "aws_iam_role_policy_attachment" "eks_node_worker_minimal" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_worker_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr_pull" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr_readonly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni_policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---------------------------------------------------------------------------
# CodeBuild role for cluster setup (creates NodePool + EC2NodeClass)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "codebuild_setup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_setup" {
  name               = "${var.name_prefix}-eks-setup-cb"
  assume_role_policy = data.aws_iam_policy_document.codebuild_setup_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-eks-setup-cb" })
}

data "aws_iam_policy_document" "codebuild_setup_policy" {
  statement {
    sid       = "EKSDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.region}:*:cluster/${var.name_prefix}"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:*:log-group:/aws/codebuild/*"]
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

  # CodeBuild reads the buildspec from S3 at build-time. Scoped tight to the
  # single buildspec object.
  statement {
    sid       = "BuildspecRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.buildspec_s3_bucket}/${var.buildspec_s3_key}"]
  }
}

resource "aws_iam_role_policy" "codebuild_setup" {
  name   = "${var.name_prefix}-eks-setup-cb"
  role   = aws_iam_role.codebuild_setup.id
  policy = data.aws_iam_policy_document.codebuild_setup_policy.json
}

# ---------------------------------------------------------------------------
# OIDC provider for IRSA
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.nim.identity[0].oidc[0].issuer
  tags            = merge(var.tags, { Name = "${var.name_prefix}-eks-oidc" })
}

# ---------------------------------------------------------------------------
# NIM IRSA role (shared across all deployments in this cluster)
#
# Trusted by any service account named "nim-sa" in any namespace.
# Grants read access to the shared S3 model profile cache bucket.
# ---------------------------------------------------------------------------

locals {
  oidc_issuer_host = replace(aws_eks_cluster.nim.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_iam_policy_document" "nim_irsa_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:*:nim-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nim_irsa" {
  name               = "${var.name_prefix}-nim-irsa"
  assume_role_policy = data.aws_iam_policy_document.nim_irsa_assume.json
  tags               = merge(var.tags, { Name = "${var.name_prefix}-nim-irsa" })
}

data "aws_iam_policy_document" "nim_irsa_s3" {
  count = var.enable_cache_iam ? 1 : 0

  statement {
    sid     = "S3CacheRead"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      var.cache_bucket_arn,
      "${var.cache_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "nim_irsa_s3" {
  count  = var.enable_cache_iam ? 1 : 0
  name   = "${var.name_prefix}-nim-irsa-s3"
  role   = aws_iam_role.nim_irsa.id
  policy = data.aws_iam_policy_document.nim_irsa_s3[0].json
}


# IAM propagation delay — CodeBuild hits AccessDenied if triggered too soon after role creation.
# 120s covers all roles created in this module (cluster, node, codebuild) since they all feed
# into the cluster creation and CodeBuild trigger that follows. History: 30s → 60s → 120s, each
# bump driven by observed propagation-race failures in fresh accounts. A polling gate would be
# the proper structural fix; see codebuild.tf for the same pattern + history.
resource "time_sleep" "codebuild_setup_iam_propagation" {
  create_duration = "120s"
  depends_on = [
    aws_iam_role.eks_cluster,
    aws_iam_role.eks_node,
    aws_iam_role.codebuild_setup,
    aws_iam_role_policy.codebuild_setup,
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_compute_policy,
    aws_iam_role_policy_attachment.eks_block_storage_policy,
    aws_iam_role_policy_attachment.eks_load_balancing_policy,
    aws_iam_role_policy_attachment.eks_networking_policy,
    aws_iam_role_policy_attachment.eks_node_worker_minimal,
    aws_iam_role_policy_attachment.eks_node_worker_policy,
    aws_iam_role_policy_attachment.eks_node_ecr_pull,
    aws_iam_role_policy_attachment.eks_node_ecr_readonly,
    aws_iam_role_policy_attachment.eks_node_cni_policy,
  ]
}
