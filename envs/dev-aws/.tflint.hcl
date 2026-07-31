# tflint configuration for this root module.
#
#   tflint --init      # fetch the plugins below, once
#   tflint             # or: make tflint from the repository root

config {
  # Every finding is an error. A warning nobody acts on is noise, and the
  # pipeline gates provisioning on this command's exit code.
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The AWS ruleset knows about instance types, AMI attributes and the shape of
# provider arguments - things the generic ruleset cannot check.
plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Naming: lowercase, digits and underscores. Catches the copy-paste that leaves
# a resource called "web-2" next to one called "web".
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# A variable without a description is a variable nobody else can use.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Every variable declared must be typed.
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

# Unused declarations: the rule that caught vpc_cidr after the VPC became a data
# source.
rule "terraform_unused_declarations" {
  enabled = true
}
