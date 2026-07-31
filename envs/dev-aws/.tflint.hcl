#   tflint --init      # fetch the plugins below, once
#   tflint             # or: make tflint from the repository root

config {
  call_module_type = "local"
  force            = false # every finding is an error: the pipeline gates on the exit code
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Knows about instance types, AMI attributes and provider argument shapes,
# which the generic ruleset cannot check.
plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

# Providers must be version-constrained, or a build is not reproducible.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# Caught vpc_cidr after the VPC became a data source.
rule "terraform_unused_declarations" {
  enabled = true
}
