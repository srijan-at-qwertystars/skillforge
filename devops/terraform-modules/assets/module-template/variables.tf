###############################################################################
# Input Variables
#
# Guidelines:
#   - Every variable MUST have a description
#   - Use strong types (avoid 'any')
#   - Add validation blocks for domain constraints
#   - Mark secrets as sensitive = true
#   - Use optional() for complex object attributes (Terraform 1.3+)
###############################################################################

variable "name" {
  type        = string
  description = "Name prefix for all resources created by this module."

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 64
    error_message = "Name must be 1-64 characters."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources."
  default     = {}
}

# TODO: Add module-specific variables below
