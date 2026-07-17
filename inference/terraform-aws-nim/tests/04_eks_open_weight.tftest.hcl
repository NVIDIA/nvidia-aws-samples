# Apply and invoke run blocks are commented out pending resolution of
# https://github.com/hashicorp/terraform/issues/33786 (terraform test holds state in
# memory only; if destroy fails, resources are orphaned with no state file and no clean
# path to destroy them). All active tests validate successful plan only.

run "plan" {
  command = plan

  module {
    source = "./examples/eks/open-weight"
  }
}

# run "e2e" {
#   command = apply
#
#   module {
#     source = "./examples/eks/open-weight"
#   }
# }

# run "invoke" {
#   module {
#     source = "./helpers/invoke-eks-open-weight"
#   }
#
#   variables {
#     cluster_name    = run.e2e.eks_cluster_names["nemotron-9b"]
#     namespace       = run.e2e.eks_namespaces["nemotron-9b"]
#     deployment_name = run.e2e.eks_release_names["nemotron-9b"]
#     model_id        = "nvidia/NVIDIA-Nemotron-Nano-9B-v2"
#   }
# }
