# Terragrunt DRY Configuration Template
#
# Directory layout:
#   infrastructure-live/
#   ├── terragrunt.hcl              # ROOT config (Part 1)
#   ├── account.hcl                 # account_name, account_id
#   ├── prod/
#   │   ├── env.hcl                 # environment = "prod"
#   │   ├── us-east-1/
#   │   │   ├── region.hcl          # aws_region = "us-east-1"
#   │   │   ├── vpc/terragrunt.hcl  # CHILD configs (Part 2)
#   │   │   ├── rds/terragrunt.hcl
#   │   │   └── eks/terragrunt.hcl
#   │   └── eu-west-1/region.hcl
#   └── staging/
#       ├── env.hcl
#       └── us-east-1/region.hcl

# =============================================================================
# PART 1: ROOT terragrunt.hcl
# =============================================================================

# Locals — read config files from the directory hierarchy.
# `find_in_parent_folders` walks up until it finds the named file;
# `read_terragrunt_config` parses it into a usable object.
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.account_id
  aws_region   = local.region_vars.locals.aws_region
  environment  = local.env_vars.locals.environment
}
# Remote State — S3 + DynamoDB locking.
# `path_relative_to_include()` produces unique keys per child module,
# e.g. prod/us-east-1/vpc/terraform.tfstate
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "mycompany-terraform-state-${local.account_id}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "terraform-locks"

    s3_bucket_tags = {
      ManagedBy   = "terragrunt"
      Environment = local.environment
    }
  }
}
# Generate — provider.tf injected into every child before plan/apply
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"
      allowed_account_ids = ["${local.account_id}"]

      default_tags {
        tags = {
          Environment = "${local.environment}"
          ManagedBy   = "terraform"
          Account     = "${local.account_name}"
        }
      }
    }
  EOF
}
# Common Inputs — inherited by every child via `include`
inputs = {
  account_name = local.account_name
  account_id   = local.account_id
  aws_region   = local.aws_region
  environment  = local.environment
}
# =============================================================================
# PART 2: CHILD MODULE terragrunt.hcl  (e.g. prod/us-east-1/eks/terragrunt.hcl)
# =============================================================================
# Include — pull in root config (remote_state, provider, common inputs).
# `find_in_parent_folders()` with no args locates the nearest root terragrunt.hcl.
# `merge_strategy = "deep"` deep-merges inputs from root + child.
# include "root" {
#   path   = find_in_parent_folders()
#   expose = true                       # lets you reference root locals
#   merge_strategy = "deep"             # deep-merge inputs from root + child
# }
# Terraform Source — versioned module reference.
# Double-slash (//) separates repo URL from subdirectory; ?ref= pins version.
# terraform {
#   source = "git::git@github.com:myorg/terraform-modules.git//modules/eks?ref=v1.4.0"
#
#   # Lifecycle hooks
#   before_hook "validate" {
#     commands = ["apply", "plan"]
#     execute  = ["tflint", "--init"]     # lint before plan/apply
#   }
#   after_hook "notify" {
#     commands     = ["apply"]
#     execute      = ["bash", "-c", "echo 'Apply complete for EKS module'"]
#     run_on_error = false                # skip if apply failed
#   }
# }
# Dependencies — fetch outputs from other modules' state to wire stacks together.
# Mock outputs let you `plan` before a dependency is applied.
# dependency "vpc" {
#   config_path = "../vpc"
#   mock_outputs = {
#     vpc_id             = "vpc-mock-00000"
#     private_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
#   }
#   mock_outputs_allowed_terraform_commands = ["validate", "plan"]
# }
#
# dependency "rds" {
#   config_path = "../rds"
#   mock_outputs = {
#     db_endpoint = "mock-db.example.com:5432"
#   }
#   mock_outputs_allowed_terraform_commands = ["validate", "plan"]
# }
#
# Dependencies block — controls apply/destroy ordering (no output fetching)
# dependencies {
#   paths = ["../vpc", "../rds"]
# }
#
# Inputs — child-specific values merged with root; use dependency.<name>.outputs.*
# inputs = {
#   cluster_name       = "eks-${include.root.locals.environment}"
#   vpc_id             = dependency.vpc.outputs.vpc_id
#   private_subnet_ids = dependency.vpc.outputs.private_subnet_ids
#   db_endpoint        = dependency.rds.outputs.db_endpoint
#
#   node_instance_type = "m5.xlarge"
#   desired_capacity   = 3
#   max_capacity       = 10
# }
# =============================================================================
# PART 3: DRY HIERARCHY FILES
# =============================================================================
# --- account.hcl (repo root) ------------------------------------------------
# locals {
#   account_name = "mycompany-prod"
#   account_id   = "111111111111"
# }
# --- region.hcl (e.g. prod/us-east-1/region.hcl) ----------------------------
# locals {
#   aws_region = "us-east-1"
# }
# --- env.hcl (e.g. prod/env.hcl) --------------------------------------------
# locals {
#   environment = "prod"
# }

# =============================================================================
# PART 4: ADDITIONAL PATTERNS
# =============================================================================
# prevent_destroy — block accidental `terragrunt destroy` on stateful resources
# prevent_destroy = true
# skip — exclude a module from `run-all` (useful during migrations)
# skip = true

# Generate — additional common files (multiple generate blocks can coexist)
# generate "versions" {
#   path      = "versions.tf"
#   if_exists = "overwrite_terragrunt"
#   contents  = <<-EOF
#     terraform {
#       required_version = ">= 1.5"
#       required_providers {
#         aws = {
#           source  = "hashicorp/aws"
#           version = "~> 5.0"
#         }
#       }
#     }
#   EOF
# }
