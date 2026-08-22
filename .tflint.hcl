# This repository treats modules under terraform/modules as private, local
# implementation details. Terraform and provider version selection therefore
# lives in terraform/providers.tf instead of being repeated in every module.
rule "terraform_required_version" {
  enabled = false
}

rule "terraform_required_providers" {
  enabled = false
}
