# Apply and invoke run blocks are commented out pending resolution of
# https://github.com/hashicorp/terraform/issues/33786 (terraform test holds state in
# memory only; if destroy fails, resources are orphaned with no state file and no clean
# path to destroy them). All active tests validate successful plan only.

run "plan" {
  command = plan

  module {
    source = "./examples/all-inference"
  }

  variables {
    ngc_secret_name = "nvidia-general-nv-developer"
  }
}

# run "e2e" {
#   command = apply
#
#   module {
#     source = "./examples/all-inference"
#   }
#
#   variables {
#     ngc_secret_name = "nvidia-general-nv-developer"
#   }
# }

# run "invoke_sagemaker_nim" {
#   module {
#     source = "./helpers/invoke-sagemaker"
#   }
#
#   variables {
#     endpoint_name = run.e2e.endpoint_names["nemotron-9b-nim"]
#     model         = "nvidia/nvidia-nemotron-nano-9b-v2"
#   }
# }

# run "invoke_sagemaker_open_weight" {
#   module {
#     source = "./helpers/invoke-sagemaker"
#   }
#
#   variables {
#     endpoint_name = run.e2e.endpoint_names["nemotron-9b-hf"]
#     model         = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"
#   }
# }

# run "invoke_eks_nim" {
#   module {
#     source = "./helpers/invoke-eks-nim"
#   }
#
#   variables {
#     cluster_name = run.e2e.eks_cluster_names["nemotron-9b"]
#     namespace    = run.e2e.eks_namespaces["nemotron-9b-nim-eks"]
#     release_name = run.e2e.eks_release_names["nemotron-9b-nim-eks"]
#     model_id     = "nvidia/nvidia-nemotron-nano-9b-v2"
#   }
# }

# run "invoke_eks_open_weight" {
#   module {
#     source = "./helpers/invoke-eks-open-weight"
#   }
#
#   variables {
#     cluster_name    = run.e2e.eks_cluster_names["nemotron-9b"]
#     namespace       = run.e2e.eks_namespaces["nemotron-9b-ow-eks"]
#     deployment_name = run.e2e.eks_release_names["nemotron-9b-ow-eks"]
#     model_id        = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"
#   }
# }
