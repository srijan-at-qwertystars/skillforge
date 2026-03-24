# TFLint Configuration Template
#
# Place this file as .tflint.hcl in your module root.
# Initialize plugins: tflint --init
# Run: tflint --recursive
#
# Documentation: https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md

###############################################################################
# Global Configuration
###############################################################################

config {
  # "compact", "default", "json", "junit", "sarif"
  format = "compact"

  # Enable module inspection (checks called modules too)
  module = true

  # Force specific behavior
  force = false
}

###############################################################################
# Terraform Plugin — Core HCL Rules
###############################################################################

plugin "terraform" {
  enabled = true
  # "recommended" enables a curated set of rules; "all" enables everything
  preset = "recommended"
}

# Enforce consistent naming: snake_case for all identifiers
rule "terraform_naming_convention" {
  enabled = true

  variable {
    format = "snake_case"
  }

  locals {
    format = "snake_case"
  }

  output {
    format = "snake_case"
  }

  resource {
    format = "snake_case"
  }

  data {
    format = "snake_case"
  }

  module {
    format = "snake_case"
  }
}

# Require descriptions on all variables
rule "terraform_documented_variables" {
  enabled = true
}

# Require descriptions on all outputs
rule "terraform_documented_outputs" {
  enabled = true
}

# Enforce standard module structure (main.tf, variables.tf, outputs.tf)
rule "terraform_standard_module_structure" {
  enabled = true
}

# Require version constraints on terraform block
rule "terraform_required_version" {
  enabled = true
}

# Require version constraints on all required_providers
rule "terraform_required_providers" {
  enabled = true
}

# Flag unused declarations
rule "terraform_unused_declarations" {
  enabled = true
}

# Flag deprecated interpolation syntax
rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Warn on empty list default
rule "terraform_empty_list_equality" {
  enabled = true
}

# Enforce workspace remote backend (disable if not using TFC)
rule "terraform_workspace_remote" {
  enabled = false
}

###############################################################################
# AWS Plugin — Provider-Specific Rules
# Uncomment and configure for AWS modules
###############################################################################

# plugin "aws" {
#   enabled = true
#   version = "0.31.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-aws"
# }
#
# # Flag invalid EC2 instance types
# rule "aws_instance_invalid_type" {
#   enabled = true
# }
#
# # Flag invalid RDS instance classes
# rule "aws_db_instance_invalid_type" {
#   enabled = true
# }
#
# # Require tags on taggable resources
# rule "aws_resource_missing_tags" {
#   enabled = true
#   tags = [
#     "Environment",
#     "Team",
#     "ManagedBy",
#   ]
# }

###############################################################################
# Google Plugin — Uncomment for GCP modules
###############################################################################

# plugin "google" {
#   enabled = true
#   version = "0.28.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-google"
# }

###############################################################################
# Azure Plugin — Uncomment for Azure modules
###############################################################################

# plugin "azurerm" {
#   enabled = true
#   version = "0.26.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
# }
