#!/usr/bin/env bash
#
# scaffold-module.sh — Generate a new Terraform module directory with standard layout.
#
# Usage:
#   ./scaffold-module.sh <module-name> [provider]
#
# Arguments:
#   module-name  Name of the module (e.g., "vpc", "ecs-service", "rds-cluster")
#   provider     Provider name (default: "aws")
#
# Examples:
#   ./scaffold-module.sh vpc
#   ./scaffold-module.sh ecs-service aws
#   ./scaffold-module.sh gke-cluster google
#
# Creates the following structure:
#   terraform-<provider>-<module-name>/
#   ├── main.tf
#   ├── variables.tf
#   ├── outputs.tf
#   ├── versions.tf
#   ├── README.md
#   ├── examples/
#   │   └── complete/
#   │       ├── main.tf
#   │       └── outputs.tf
#   └── tests/
#       └── main.tftest.hcl
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <module-name> [provider]"
  echo "Example: $0 vpc aws"
  exit 1
fi

MODULE_NAME="$1"
PROVIDER="${2:-aws}"
MODULE_DIR="terraform-${PROVIDER}-${MODULE_NAME}"

if [[ -d "$MODULE_DIR" ]]; then
  echo "Error: Directory '$MODULE_DIR' already exists."
  exit 1
fi

echo "Scaffolding module: $MODULE_DIR"

mkdir -p "$MODULE_DIR"/{examples/complete,tests}

# --- main.tf ---
cat > "$MODULE_DIR/main.tf" << 'HEREDOC'
###############################################################################
# Main resource definitions
###############################################################################

locals {
  common_tags = merge(var.tags, {
    Module    = var.name
    ManagedBy = "terraform"
  })
}

# TODO: Add your resources here
HEREDOC

# --- variables.tf ---
cat > "$MODULE_DIR/variables.tf" << 'HEREDOC'
###############################################################################
# Input Variables
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
  description = "Deployment environment (e.g., dev, staging, prod)."
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
HEREDOC

# --- outputs.tf ---
cat > "$MODULE_DIR/outputs.tf" << 'HEREDOC'
###############################################################################
# Outputs
###############################################################################

# TODO: Expose outputs that consumers need
# output "id" {
#   value       = aws_resource.main.id
#   description = "The ID of the created resource."
# }
HEREDOC

# --- versions.tf ---
PROVIDER_SOURCE="hashicorp/${PROVIDER}"
cat > "$MODULE_DIR/versions.tf" << HEREDOC
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    ${PROVIDER} = {
      source  = "${PROVIDER_SOURCE}"
      version = ">= 5.0"
    }
  }
}
HEREDOC

# --- README.md ---
cat > "$MODULE_DIR/README.md" << HEREDOC
# ${MODULE_DIR}

Terraform module for managing ${MODULE_NAME} resources on ${PROVIDER}.

## Usage

\`\`\`hcl
module "${MODULE_NAME//-/_}" {
  source = "git::https://github.com/org/${MODULE_DIR}.git?ref=v1.0.0"

  name        = "my-${MODULE_NAME}"
  environment = "prod"
}
\`\`\`

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.6.0 |
| ${PROVIDER} | >= 5.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| name | Name prefix for all resources | \`string\` | n/a | yes |
| environment | Deployment environment | \`string\` | \`"dev"\` | no |
| tags | Additional tags to apply | \`map(string)\` | \`{}\` | no |

## Outputs

| Name | Description |
|------|-------------|
| — | — |

## Examples

See the [examples/complete](examples/complete) directory.

## Tests

\`\`\`bash
terraform test
\`\`\`

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
HEREDOC

# --- examples/complete/main.tf ---
cat > "$MODULE_DIR/examples/complete/main.tf" << HEREDOC
###############################################################################
# Complete Example — ${MODULE_DIR}
###############################################################################

provider "${PROVIDER}" {
  region = "us-east-1"
}

module "${MODULE_NAME//-/_}" {
  source = "../../"

  name        = "example-${MODULE_NAME}"
  environment = "dev"

  tags = {
    Example = "true"
  }
}
HEREDOC

# --- examples/complete/outputs.tf ---
cat > "$MODULE_DIR/examples/complete/outputs.tf" << 'HEREDOC'
###############################################################################
# Example Outputs
###############################################################################

# output "id" {
#   value = module.<module_name>.id
# }
HEREDOC

# --- tests/main.tftest.hcl ---
cat > "$MODULE_DIR/tests/main.tftest.hcl" << HEREDOC
###############################################################################
# Tests — ${MODULE_DIR}
###############################################################################

variables {
  name        = "test-${MODULE_NAME}"
  environment = "dev"
}

run "validates_name_cannot_be_empty" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "validates_environment_values" {
  command = plan

  variables {
    environment = "invalid"
  }

  expect_failures = [var.environment]
}

run "plan_succeeds_with_defaults" {
  command = plan

  assert {
    condition     = var.name == "test-${MODULE_NAME}"
    error_message = "Name variable not set correctly."
  }
}
HEREDOC

echo "✓ Created $MODULE_DIR/ with standard module layout"
echo ""
echo "Next steps:"
echo "  cd $MODULE_DIR"
echo "  # Add resources to main.tf"
echo "  # Add variables to variables.tf"
echo "  # Add outputs to outputs.tf"
echo "  terraform init && terraform validate"
