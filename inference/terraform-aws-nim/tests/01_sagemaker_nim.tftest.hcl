# Apply and invoke run blocks are commented out pending resolution of
# https://github.com/hashicorp/terraform/issues/33786 (terraform test holds state in
# memory only; if destroy fails, resources are orphaned with no state file and no clean
# path to destroy them). All active tests validate successful plan only.

run "plan" {
  command = plan

  module {
    source = "./examples/sagemaker/nim"
  }

  variables {
    ngc_secret_name = "nvidia-general-nv-developer"
  }
}

# run "e2e" {
#   command = apply
#
#   module {
#     source = "./examples/sagemaker/nim"
#   }
#
#   variables {
#     ngc_secret_name = "nvidia-general-nv-developer"
#   }
# }

# run "invoke" {
#   module {
#     source = "./helpers/invoke-sagemaker"
#   }
#
#   variables {
#     endpoint_name = run.e2e.endpoint_names["nemotron-9b"]
#     model         = "nvidia/nvidia-nemotron-nano-9b-v2"
#   }
# }
