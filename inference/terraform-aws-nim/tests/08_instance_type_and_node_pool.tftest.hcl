# Offline tests (mocked AWS provider — no credentials needed) for the two ways to choose
# GPU nodes: eks_clusters[*].instance_type (pin one type) and eks_clusters[*].node_pool
# (let Karpenter choose by family / VRAM, optionally with capacity reservations).

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"*\"}]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "random" {}

variables {
  project_prefix  = "nimtest"
  environment     = "dev"
  region          = "us-east-1"
  ngc_credentials = { api_key = "test" }
}

# A cluster that sets instance_type (and no node_pool) renders exactly the NodePool the
# module produced before node_pool existed: pinned to that type, on-demand, amd64.
run "instance_type_renders_original_nodepool" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.12xlarge"
      }
    }
  }

  assert {
    condition = yamldecode(output.eks_nodepool_manifests["gpu"]) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata   = { name = "nimtest-dev-gpu-gpu" }
      spec = {
        template = {
          spec = {
            nodeClassRef = { group = "eks.amazonaws.com", kind = "NodeClass", name = "default" }
            requirements = [
              { key = "node.kubernetes.io/instance-type", operator = "In", values = ["g6e.12xlarge"] },
              { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
              { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            ]
          }
        }
        limits     = { "nvidia.com/gpu" = "100" }
        disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "1m" }
      }
    }
    error_message = "instance_type must render the original single-type NodePool"
  }
}

run "instance_type_and_node_pool_together_rejected" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
        node_pool          = { instance_families = ["g6e"] }
      }
    }
  }

  expect_failures = [var.eks_clusters]
}

# node_pool: family allow-list + VRAM floor, no reservations → default NodeClass.
run "node_pool_family_and_vram" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_families = ["g6e", "g7e"], min_gpu_memory_gib = 40, max_gpus = 4 }
      }
    }
  }

  assert {
    condition     = strcontains(output.eks_nodepool_manifests["gpu"], "eks.amazonaws.com/instance-family") && !strcontains(output.eks_nodepool_manifests["gpu"], "kind: NodeClass\nmetadata")
    error_message = "node_pool should render an instance-family requirement and no custom NodeClass"
  }
  assert {
    condition     = yamldecode(output.eks_nodepool_manifests["gpu"]).spec.limits["nvidia.com/gpu"] == "4"
    error_message = "max_gpus should become the NodePool GPU limit"
  }
}

# node_pool with a capacity reservation → custom NodeClass with role / subnets / SGs and
# the reservation selector, applied before the NodePool.
run "node_pool_capacity_reservation_nodeclass" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-c"]
        node_pool = {
          instance_families        = ["p5"]
          capacity_reservation_ids = ["cr-0123456789abcdef0"]
        }
      }
    }
  }

  assert {
    condition = (
      yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[0]).kind == "NodeClass"
      && yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[0]).spec.role == "nimtest-dev-gpu-eks-node"
      && length(yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[0]).spec.subnetSelectorTerms) == 2
      && length(yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[0]).spec.securityGroupSelectorTerms) == 1
      && yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[0]).spec.capacityReservationSelectorTerms[0].id == "cr-0123456789abcdef0"
    )
    error_message = "custom NodeClass must set role, subnetSelectorTerms, securityGroupSelectorTerms and the reservation"
  }
  assert {
    condition     = yamldecode(split("\n---\n", output.eks_nodepool_manifests["gpu"])[1]).spec.template.spec.nodeClassRef.name == "nimtest-dev-gpu-gpu-nc"
    error_message = "NodePool must reference the custom NodeClass"
  }
}

# GPU count derives from the cluster's instance_type: g6e.xlarge has 1 GPU, so asking for
# 2 trips the precondition (proves the derivation + check use the cluster type).
run "gpu_count_checked_against_cluster_instance_type" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          gpu_count               = 2
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

# The profile cache is built for one GPU: it needs a pinned type, from the cluster's
# instance_type or exactly one node_selection.instance_types entry.
run "cache_requires_pinned_type" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_families = ["g6e"] }
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key                = "gpu"
          source_image_uri           = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version         = "1.0.0"
          nlb_allowed_cidr_blocks    = ["10.0.0.0/8"]
          enable_model_profile_cache = true
          node_selection             = { min_gpu_memory_gib = 20 }
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

run "cache_ok_with_cluster_instance_type" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key                = "gpu"
          source_image_uri           = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version         = "1.0.0"
          nlb_allowed_cidr_blocks    = ["10.0.0.0/8"]
          enable_model_profile_cache = true
        }
      }
    }
  }
}

run "ngc_api_key_in_env_rejected" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        custom = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/nvidia/example:1.0.0"
          nim_type                = "custom"
          protocol                = "grpc"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          env                     = { NGC_API_KEY = "oops" }
        }
      }
    }
  }

  expect_failures = [var.eks_deployments]
}

# node_pool.instance_types: exact-type allow-list (Karpenter still picks the cheapest).
run "node_pool_instance_types_allow_list" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_types = ["g6e.xlarge", "g6e.2xlarge"] }
      }
    }
  }

  assert {
    condition = anytrue([
      for r in yamldecode(output.eks_nodepool_manifests["gpu"]).spec.template.spec.requirements :
      r.key == "node.kubernetes.io/instance-type" && r.operator == "In" && r.values == ["g6e.xlarge", "g6e.2xlarge"]
    ])
    error_message = "node_pool.instance_types should render an instance-type In requirement"
  }
}

# types and families together render both requirements (Karpenter ANDs them).
run "node_pool_instance_types_and_families" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_types = ["g6e.xlarge"], instance_families = ["g6e"] }
      }
    }
  }

  assert {
    condition = (
      anytrue([for r in yamldecode(output.eks_nodepool_manifests["gpu"]).spec.template.spec.requirements : r.key == "node.kubernetes.io/instance-type"])
      && anytrue([for r in yamldecode(output.eks_nodepool_manifests["gpu"]).spec.template.spec.requirements : r.key == "eks.amazonaws.com/instance-family"])
    )
    error_message = "types and families should both be rendered"
  }
}

# A node_pool that allows exactly one type pins it like instance_type does: the GPU-count
# check uses it (g6e.xlarge has 1 GPU, so gpu_count = 2 fails).
run "single_type_node_pool_pins_gpu_count" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_types = ["g6e.xlarge"] }
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          gpu_count               = 2
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

run "node_pool_instance_types_rejects_ml_prefix" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_types = ["ml.g6e.xlarge"] }
      }
    }
  }

  expect_failures = [var.eks_clusters]
}

# use_reserved_first on a cluster with no node_pool (only instance_type) must fail with the
# intended validation message, not an attribute-on-null error.
run "use_reserved_first_without_node_pool_rejected_cleanly" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          node_selection          = { use_reserved_first = true, instance_types = ["g6e.xlarge"] }
        }
      }
    }
  }

  expect_failures = [var.eks_deployments]
}

# node_selection.instance_types must be allowed by the cluster: a type outside the cluster's
# node_pool families can never schedule, so it is rejected at plan time.
run "node_selection_type_outside_cluster_families_rejected" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_families = ["g5"] }
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          node_selection          = { instance_types = ["g6e.xlarge"] }
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

run "node_selection_type_outside_cluster_type_list_rejected" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_types = ["g6e.xlarge"] }
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          node_selection          = { instance_types = ["g6e.2xlarge"] }
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

run "node_selection_type_differs_from_cluster_instance_type_rejected" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version      = "1.0.0"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          node_selection          = { instance_types = ["g6e.2xlarge"] }
        }
      }
    }
  }

  expect_failures = [terraform_data.validation]
}

# Allowed combinations plan: a type inside the cluster's families, and the cluster's own type.
run "node_selection_type_inside_cluster_pool_ok" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        node_pool          = { instance_families = ["g6e", "g7e"], instance_types = null }
      }
    }
    eks_deployments = {
      nim = {
        llm = {
          cluster_key                = "gpu"
          source_image_uri           = "nvcr.io/nim/meta/llama-3.1-8b-instruct:1.8.3"
          helm_chart_version         = "1.0.0"
          nlb_allowed_cidr_blocks    = ["10.0.0.0/8"]
          enable_model_profile_cache = true
          node_selection             = { instance_types = ["g6e.xlarge"] }
        }
      }
    }
  }
}

# env keys become environment variable names: reject keys that aren't valid names; values may
# contain newlines and "=" (they are framed as base64 on the way to CodeBuild).
run "env_key_must_be_a_valid_name" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        custom = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/nvidia/example:1.0.0"
          nim_type                = "custom"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          env                     = { "BAD=KEY" = "x" }
        }
      }
    }
  }

  expect_failures = [var.eks_deployments]
}

run "env_value_with_newline_and_equals_ok" {
  command = plan

  variables {
    eks_clusters = {
      gpu = {
        vpc_id             = "vpc-1"
        private_subnet_ids = ["subnet-a"]
        public_subnet_ids  = ["subnet-c"]
        instance_type      = "g6e.xlarge"
      }
    }
    eks_deployments = {
      nim = {
        custom = {
          cluster_key             = "gpu"
          source_image_uri        = "nvcr.io/nim/nvidia/example:1.0.0"
          nim_type                = "custom"
          protocol                = "grpc"
          nlb_allowed_cidr_blocks = ["10.0.0.0/8"]
          env                     = { A = "x\nB=y", C = "a=b" }
        }
      }
    }
  }
}
