# tflint configuration for terraform-aws-nim
#
# Run manually from the module root:
#   tflint --config=.tflint.hcl
#
# Or via pre-commit:
#   pre-commit run terraform_tflint --all-files

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Enforce documented variable descriptions
rule "terraform_documented_variables" {
  enabled = true
}

# Enforce documented output descriptions
rule "terraform_documented_outputs" {
  enabled = true
}

# Flag naming convention violations (snake_case)
rule "terraform_naming_convention" {
  enabled = true

  variable {
    format = "snake_case"
  }
  output {
    format = "snake_case"
  }
  locals {
    format = "snake_case"
  }
  resource {
    format = "snake_case"
  }
  module {
    format = "none"
  }
}

# Warn on deprecated interpolation syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Require module version pinning (disable for local module references)
rule "terraform_module_pinned_source" {
  enabled = false
}
