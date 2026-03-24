---
name: terraform-modules
description: >
  Guide for authoring, composing, versioning, testing, and publishing reusable
  Terraform modules using HCL. Triggers on: "terraform module", "tf module
  composition", "terraform registry", "module versioning", "terraform
  workspaces", "terraform state management", "terratest", "terraform test",
  "module inputs outputs", "terraform remote module", "terraform CI/CD",
  "terraform provider configuration", "HCL module pattern".
  NOT for Pulumi, CloudFormation, CDK, Ansible, or general cloud provider
  questions unrelated to Terraform module design.
---

# Terraform Modules — Authoring & Operations Guide

## Module Structure

Use the canonical layout. Every module repository follows `terraform-<PROVIDER>-<NAME>`.

```
modules/my-module/
├── main.tf          # Resource definitions
├── variables.tf     # All input variables
├── outputs.tf       # All outputs
├── versions.tf      # Required providers & terraform version
├── providers.tf     # Provider configuration (root modules only)
├── locals.tf        # Computed locals
├── data.tf          # Data sources
├── README.md
├── examples/
│   └── complete/
│       ├── main.tf
│       └── outputs.tf
└── tests/
    └── main.tftest.hcl
```

Keep each module single-purpose. If description exceeds one sentence, split.

## versions.tf — Pin Everything

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Never declare `provider` blocks inside reusable child modules — accept them via `configuration_aliases` or inherit from the calling root module.

## Input Variables

Define in `variables.tf`. Use strong types, defaults, descriptions, and validation.

```hcl
variable "name" {
  type        = string
  description = "Name prefix for all resources."

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
    error_message = "Must be dev, staging, or prod."
  }
}

variable "tags" {
  type        = map(string)
  description = "Resource tags to apply."
  default     = {}
}

variable "enable_logging" {
  type        = bool
  description = "Enable access logging."
  default     = false
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Database password. Marked sensitive."
}
```

Use `object()` and `optional()` for complex inputs (Terraform 1.3+):

```hcl
variable "scaling" {
  type = object({
    min_size     = number
    max_size     = number
    desired      = optional(number, 2)
    cpu_target   = optional(number, 70)
  })
  description = "Auto-scaling parameters."
}
```

## Output Variables

Expose only what consumers need in `outputs.tf`.

```hcl
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the created VPC."
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "List of private subnet IDs."
}

output "db_connection_string" {
  value       = "postgresql://${aws_db_instance.main.endpoint}/${var.db_name}"
  sensitive   = true
  description = "Database connection string."
}
```

## Module Composition Patterns

### Flat Composition — root calls independent child modules

```hcl
module "network" {
  source      = "./modules/network"
  cidr_block  = "10.0.0.0/16"
  environment = var.environment
}

module "compute" {
  source     = "./modules/compute"
  subnet_ids = module.network.private_subnet_ids
  vpc_id     = module.network.vpc_id
}
```

### Facade — wrapper encapsulates child modules

```hcl
# modules/platform/main.tf
module "network" { source = "../network"; cidr = var.cidr }
module "eks" {
  source     = "../eks"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
}
output "cluster_endpoint" { value = module.eks.endpoint }
```

### for_each — stamp multiple instances

```hcl
variable "services" {
  type = map(object({ image = string, cpu = number, port = number }))
}

module "service" {
  source   = "./modules/ecs-service"
  for_each = var.services
  name     = each.key
  image    = each.value.image
  cpu      = each.value.cpu
  port     = each.value.port
}
```

## Remote Module Sources

```hcl
# Terraform Registry (public or private)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}

# Git repository (pin to tag)
module "custom" {
  source = "git::https://github.com/org/terraform-modules.git//modules/rds?ref=v2.1.0"
}

# S3 bucket
module "lambda" {
  source = "s3::https://s3-us-east-1.amazonaws.com/my-tf-modules/lambda-v1.0.0.zip"
}
```

Always pin with `version` (registry) or `ref`/tag (git). Never use `ref=main`.

## Versioning Strategies

Use Semantic Versioning: `MAJOR.MINOR.PATCH`.

| Change type | Bump | Example |
|---|---|---|
| Breaking variable/output rename | MAJOR | 1.0.0 → 2.0.0 |
| New optional variable | MINOR | 1.0.0 → 1.1.0 |
| Bug fix, docs | PATCH | 1.1.0 → 1.1.1 |

Version constraint operators:

```hcl
version = "5.1.0"      # Exact
version = "~> 5.1"     # >= 5.1.0, < 6.0.0
version = ">= 5.0, < 6.0"  # Range
```

Use `moved` blocks for safe refactoring without state loss:

```hcl
moved {
  from = aws_instance.old_name
  to   = aws_instance.new_name
}
```

## Workspace Management

```hcl
locals {
  env_config = {
    dev  = { instance_type = "t3.small",  count = 1 }
    staging = { instance_type = "t3.medium", count = 2 }
    prod = { instance_type = "m5.large",  count = 3 }
  }
  env = local.env_config[terraform.workspace]
}

resource "aws_instance" "app" {
  count         = local.env.count
  instance_type = local.env.instance_type
  ami           = var.ami_id
}
```

Commands: `terraform workspace new staging && terraform workspace select staging && terraform plan`

## State Management Patterns

### Remote backend (S3 + DynamoDB locking)

```hcl
terraform {
  backend "s3" {
    bucket = "my-tf-state"
    key    = "infra/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "tf-lock"
    encrypt = true
  }
}
```

### Cross-stack references via remote state

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = "my-tf-state", key = "network/terraform.tfstate", region = "us-east-1" }
}

resource "aws_instance" "app" {
  subnet_id = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
}
```

Prefer passing outputs explicitly over remote state when modules are in the same root.

## Provider Configuration

Root modules configure providers; child modules only declare requirements.

```hcl
# Root module
provider "aws" { region = "us-east-1" }
provider "aws" { alias = "west"; region = "us-west-2" }

module "replica" {
  source    = "./modules/s3-replica"
  providers = { aws.primary = aws, aws.replica = aws.west }
}
```

```hcl
# modules/s3-replica/versions.tf — child declares aliases it expects
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.replica]
    }
  }
}
```

## Testing Modules

### Native terraform test (>= 1.6)

Place `*.tftest.hcl` files in `tests/` or module root.

```hcl
# tests/main.tftest.hcl

variables {
  name        = "test-vpc"
  environment = "dev"
  cidr_block  = "10.0.0.0/16"
}

run "creates_vpc" {
  command = plan

  assert {
    condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR mismatch."
  }
}

run "validates_tags" {
  command = plan

  assert {
    condition     = aws_vpc.main.tags["Environment"] == "dev"
    error_message = "Environment tag not set."
  }
}

run "full_apply" {
  command = apply

  assert {
    condition     = output.vpc_id != ""
    error_message = "VPC ID must not be empty."
  }
}
```

Run with:

```bash
terraform test
terraform test -filter=tests/main.tftest.hcl
```

### Terratest (Go)

```go
func TestVpcModule(t *testing.T) {
  t.Parallel()
  opts := &terraform.Options{
    TerraformDir: "../examples/complete",
    Vars: map[string]interface{}{"name": "test", "environment": "dev"},
  }
  defer terraform.Destroy(t, opts)
  terraform.InitAndApply(t, opts)
  assert.NotEmpty(t, terraform.Output(t, opts, "vpc_id"))
}
```

### Static analysis

```bash
terraform fmt -check -recursive && terraform validate && tflint --recursive
```

## CI/CD Pipeline for Modules

```yaml
# .github/workflows/module-ci.yml
name: Module CI
on:
  pull_request: { branches: [main] }
  push: { tags: ["v*"] }
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.9.0" }
      - run: terraform fmt -check -recursive
      - run: terraform init -backend=false
      - run: terraform validate
      - run: terraform test
  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Tag pushed — registry auto-publishes from GitHub release"
```

Tag releases: `git tag -a v1.2.0 -m "Add logging" && git push origin v1.2.0`

## Module Registry Publishing

**Public Registry:** Name repo `terraform-<PROVIDER>-<NAME>`, use standard structure, tag with semver (`v1.0.0`), connect GitHub to registry.terraform.io — auto-publishes on tags.

**Private Registry (TFC/TFE):** Connect VCS repo via API or UI; same semver tagging workflow applies.

## Examples

### Input: "Create a reusable VPC module"

```hcl
# modules/vpc/variables.tf
variable "cidr" {
  type        = string
  description = "VPC CIDR block."
}
variable "azs" {
  type        = list(string)
  description = "Availability zones."
}

# modules/vpc/main.tf
resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "vpc-${var.cidr}" }
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr, 8, count.index)
  availability_zone = var.azs[count.index]
  tags = { Name = "private-${var.azs[count.index]}" }
}

# modules/vpc/outputs.tf
output "vpc_id" {
  value = aws_vpc.this.id
}
output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
```

### Input: "How do I test this module?"

```hcl
# tests/vpc.tftest.hcl
variables {
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b"]
}

run "plan_vpc" {
  command = plan
  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "CIDR mismatch."
  }
  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Expected 2 private subnets."
  }
}
```

### Input: "Set up multi-region with provider aliases"

```hcl
provider "aws" { region = "us-east-1" }
provider "aws" { alias = "eu"; region = "eu-west-1" }

module "us" {
  source    = "./modules/regional"
  providers = { aws = aws }
}
module "eu" {
  source    = "./modules/regional"
  providers = { aws = aws.eu }
}
```
