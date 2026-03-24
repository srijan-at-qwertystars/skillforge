###############################################################################
# Main resource definitions
#
# Replace this boilerplate with your module's resources.
# Follow these principles:
#   - Single responsibility: one module = one logical component
#   - Use locals for computed values and tag merging
#   - Keep resources in this file; split only if main.tf exceeds ~200 lines
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module      = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# TODO: Add your resources below
#
# Example:
# resource "aws_vpc" "main" {
#   cidr_block           = var.cidr_block
#   enable_dns_support   = true
#   enable_dns_hostnames = true
#   tags                 = merge(local.common_tags, { Name = "${var.name}-vpc" })
# }
