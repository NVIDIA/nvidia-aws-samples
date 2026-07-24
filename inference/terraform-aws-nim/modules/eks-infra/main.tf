# ---------------------------------------------------------------------------
# modules/eks-infra — EKS Auto Mode cluster + cluster-setup CodeBuild
#
# Creates: EKS cluster (Auto Mode), IAM roles, security group, CloudWatch log
# group, EKS access entry for setup CodeBuild, OIDC provider, NIM IRSA role,
# and a CodeBuild project that applies the GPU NodePool + EC2NodeClass.
#
# Outputs cluster_name, cluster_security_group_id, nim_irsa_role_arn, and
# node_role_name for consumption by modules/eks-app.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# EKS cluster (Auto Mode)
#
# bootstrap_self_managed_addons = false: Auto Mode manages vpc-cni, coredns,
# kube-proxy, and EBS CSI as built-in components — do not manage them as
# separate add-ons.
#
# compute_config.node_pools: "general-purpose" and "system" are the two
# Auto Mode built-in pools. The GPU NodePool is created post-cluster by
# the cluster-setup CodeBuild action.
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "nim" {
  region   = var.region
  name     = var.name_prefix
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  compute_config {
    enabled       = true
    node_role_arn = aws_iam_role.eks_node.arn
    node_pools    = ["general-purpose", "system"]
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  enabled_cluster_log_types = var.cluster_log_types

  tags = merge(var.tags, { Name = var.name_prefix })

  depends_on = [
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
    # Log group: cluster depends on it so on DESTROY the cluster is deleted FIRST.
    # skip_destroy = true keeps the log group alive in AWS through destroy, so EKS
    # never needs to recreate it. On re-apply the provider adopts the existing one.
    aws_cloudwatch_log_group.eks_cluster,
    # LBC cleanup: cluster depends on it so on DESTROY the cluster is fully
    # deleted first, THEN the provisioner removes LBC-created SGs/ENIs.
    # Running after cluster deletion ensures those ENIs are already released.
    terraform_data.cleanup_lbc_resources,
    # IGW fence: ensures cluster is destroyed before consumer VPC/IGW resources.
    # Only present when internet_gateway_id is set (count-gated).
    terraform_data.internet_gateway_destroy_fence,
  ]
}

resource "aws_cloudwatch_log_group" "eks_cluster" {
  region            = var.region
  name              = "/aws/eks/${var.name_prefix}/cluster"
  retention_in_days = 30
  tags              = merge(var.tags, { Name = "/aws/eks/${var.name_prefix}/cluster" })
}

# ---------------------------------------------------------------------------
# EKS access entry for the cluster-setup CodeBuild role
#
# Grants AmazonEKSClusterAdminPolicy so the CodeBuild container can run
# kubectl apply for NodePool + EC2NodeClass manifests.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "codebuild_setup" {
  region        = var.region
  cluster_name  = aws_eks_cluster.nim.name
  principal_arn = aws_iam_role.codebuild_setup.arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.nim]
}

resource "aws_eks_access_policy_association" "codebuild_setup" {
  region        = var.region
  cluster_name  = aws_eks_cluster.nim.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_iam_role.codebuild_setup.arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.codebuild_setup]
}

# ---------------------------------------------------------------------------
# Additional EKS access entries (operators, CI/CD roles, developer IAM roles)
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "additional" {
  for_each = var.eks_access_entries

  region        = var.region
  cluster_name  = aws_eks_cluster.nim.name
  principal_arn = each.value.principal_arn
  type          = each.value.type

  depends_on = [aws_eks_cluster.nim]
}

resource "aws_eks_access_policy_association" "additional" {
  for_each = {
    for combo in flatten([
      for entry_key, entry in var.eks_access_entries : [
        for idx, pol in entry.policy_associations : {
          key           = "${entry_key}-${idx}"
          principal_arn = entry.principal_arn
          policy_arn    = pol.policy_arn
          access_scope  = pol.access_scope
        }
      ]
    ]) : combo.key => combo
  }

  region        = var.region
  cluster_name  = aws_eks_cluster.nim.name
  policy_arn    = each.value.policy_arn
  principal_arn = each.value.principal_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = each.value.access_scope.namespaces
  }

  depends_on = [aws_eks_access_entry.additional]
}

# ---------------------------------------------------------------------------
# CodeBuild — cluster setup
#
# Runs after the cluster is created. Applies the GPU NodePool and EC2NodeClass
# Karpenter resources that tell Auto Mode which instance types to provision for
# NIM workloads. Runs in the VPC so it can reach the private API endpoint.
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "cluster_setup" {
  region        = var.region
  name          = "${var.name_prefix}-cluster-setup"
  description   = "Configure EKS Auto Mode GPU NodePool for ${var.instance_type} NIM nodes"
  service_role  = aws_iam_role.codebuild_setup.arn
  build_timeout = 60

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "CLUSTER_NAME"
      value = aws_eks_cluster.nim.name
    }
    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }
    environment_variable {
      name  = "GPU_INSTANCE_TYPE"
      value = var.instance_type
    }
    environment_variable {
      name  = "NAME_PREFIX"
      value = var.name_prefix
    }
    environment_variable {
      name  = "VERBOSE"
      value = tostring(var.debug)
    }
    environment_variable {
      name  = "ENABLE_AUTOSCALING"
      value = tostring(var.enable_autoscaling)
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.cluster.id]
  }

  source {
    type      = "NO_SOURCE"
    buildspec = var.buildspec_s3_arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cluster-setup" })

  depends_on = [time_sleep.codebuild_setup_iam_propagation]
}

# ---------------------------------------------------------------------------
# Action trigger — fires cluster-setup after cluster create/update
# ---------------------------------------------------------------------------

action "aws_codebuild_start_build" "cluster_setup" {
  config {
    region       = var.region
    project_name = aws_codebuild_project.cluster_setup.name
    timeout      = 1800
  }
}

resource "terraform_data" "cluster_setup_trigger" {
  input = merge(
    {
      cluster_name       = aws_eks_cluster.nim.name
      cluster_version    = aws_eks_cluster.nim.version
      instance_type      = var.instance_type
      enable_autoscaling = var.enable_autoscaling
      debug              = var.debug
      buildspec_hash     = filemd5("${path.module}/buildspecs/cluster-setup.yml")
    },
    var.force_rebuild ? { force_timestamp = timestamp() } : {}
  )

  lifecycle {
    action_trigger {
      events  = [before_create, before_update]
      actions = [action.aws_codebuild_start_build.cluster_setup]
    }
  }

  depends_on = [
    aws_eks_cluster.nim,
    aws_eks_access_policy_association.codebuild_setup,
    aws_codebuild_project.cluster_setup,
  ]
}
