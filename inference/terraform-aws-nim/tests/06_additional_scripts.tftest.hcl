run "plan_sagemaker_additional_scripts" {
  command = plan

  module {
    source = "./examples/sagemaker/additional-scripts"
  }

  variables {
    ngc_secret_name      = "nvidia-general-nv-developer"
    remote_script_s3_uri = "s3://terraform-aws-nim-module-testing/remote-test.sh"
  }
}

run "plan_eks_additional_scripts" {
  command = plan

  module {
    source = "./examples/eks/additional-scripts"
  }

  variables {
    ngc_secret_name      = "nvidia-general-nv-developer"
    remote_script_s3_uri = "s3://terraform-aws-nim-module-testing/remote-test.sh"
  }
}
