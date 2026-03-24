###############################################################################
# Provider and Terraform Version Constraints
#
# Guidelines:
#   - Pin terraform required_version to a minimum
#   - Pin provider versions with ~> (pessimistic constraint)
#   - Child modules: use configuration_aliases if multiple provider configs needed
#   - Never declare 'provider' blocks in reusable child modules
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
