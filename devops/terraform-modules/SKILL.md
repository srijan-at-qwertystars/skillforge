---
name: terraform-modules
description: >
  Guide for designing, building, testing, and managing Terraform modules and infrastructure as code.
  Use when working with Terraform modules, HCL configuration, infrastructure as code, module
  composition, Terraform Registry, state management, remote backends, workspaces, provider
  configuration, variable validation, moved/import/removed blocks, terraform test, or CI/CD
  pipelines for infrastructure. Do NOT use for Pulumi, AWS CloudFormation, AWS CDK, Ansible
  playbooks, Chef/Puppet, or simple shell scripts that do not involve infrastructure as code.
---

# Terraform Modules

## Module Structure

Organize every module with this standard layout:

```
modules/my-module/
├── main.tf          # Resources and data sources
├── variables.tf     # Input variable declarations
├── outputs.tf       # Output value declarations
├── versions.tf      # Required providers and terraform version
├── locals.tf        # Local values and computed expressions
├── README.md        # Usage docs, examples, inputs/outputs table
├── examples/
│   └── complete/    # Runnable example configuration
└── tests/
    └── main.tftest.hcl
```

Place `versions.tf` at the root with required version constraints:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}
```

## Module Design Principles

- **Single responsibility** — one module manages one logical component (VPC, database, app).
- **Composability** — expose outputs that other modules consume; accept resource IDs as inputs.
- **Backward compatibility** — add new variables with defaults; never remove outputs without deprecation.
- **No hardcoded values** — parameterize regions, names, tags, and sizing via variables.
- **No provider config in child modules** — define providers only in root modules.
- **Minimal blast radius** — keep resource count per module under ~20; split larger modules.

## Input Variables

Declare typed variables with validation, descriptions, and defaults:

```hcl
variable "instance_type" {
  description = "EC2 instance type for web servers"
  type        = string
  default     = "t3.micro"
  validation {
    condition     = can(regex("^t3\\.", var.instance_type))
    error_message = "Only t3 instance types are allowed."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

variable "subnet_config" {
  description = "Subnet definitions"
  type = list(object({
    cidr_block        = string
    availability_zone = string
    public            = optional(bool, false)
  }))
}
```

Use `optional()` with defaults for object attributes (Terraform 1.3+). Mark secrets `sensitive = true`.

## Outputs

Declare outputs with descriptions. Use conditional values for optional resources:

```hcl
output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "db_endpoint" {
  description = "Database connection endpoint"
  value       = var.create_db ? aws_db_instance.main[0].endpoint : null
  sensitive   = true
}
```

## Module Sources

```hcl
# Local path
module "vpc" { source = "./modules/vpc" }

# Git with tag
module "vpc" {
  source = "git::https://github.com/org/terraform-aws-vpc.git?ref=v3.2.0"
}

# Terraform Registry with version constraint
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}

# S3 bucket
module "vpc" {
  source = "s3::https://s3-eu-west-1.amazonaws.com/bucket/vpc-module.zip"
}
```

Pin versions explicitly. Use `~>` for minor version flexibility. Never use unversioned registry modules in production.

## Module Versioning

Follow semantic versioning for published modules:

- **MAJOR** — breaking changes (removed variables, renamed outputs, changed resource types).
- **MINOR** — new features with backward-compatible defaults.
- **PATCH** — bug fixes, documentation updates.

Tag releases: `git tag v1.2.0 && git push origin v1.2.0`. Maintain CHANGELOG.md.

## Module Composition and Nesting

Compose infrastructure from focused modules in root configurations:

```hcl
module "vpc" {
  source      = "./modules/vpc"
  cidr_block  = "10.0.0.0/16"
  environment = var.environment
}

module "eks" {
  source          = "./modules/eks"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
  cluster_version = "1.29"
}

module "app" {
  source       = "./modules/app"
  cluster_name = module.eks.cluster_name
  db_endpoint  = module.rds.endpoint
}
```

Limit nesting to 2 levels. Use `for_each` to instantiate modules per environment or region:

```hcl
module "regional_vpc" {
  for_each = toset(["us-east-1", "eu-west-1"])
  source   = "./modules/vpc"
  region   = each.key
}
```

## State Management

### Remote Backends

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "prod/vpc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

Use DynamoDB (S3), Cloud Storage (GCS), or Blob lease (Azure) for state locking. Structure keys: `{env}/{component}/terraform.tfstate`.

### Import Blocks (1.5+)

Import existing resources into state declaratively:

```hcl
import {
  to = aws_s3_bucket.legacy
  id = "my-existing-bucket"
}

resource "aws_s3_bucket" "legacy" {
  bucket = "my-existing-bucket"
}
```

Run `terraform plan` to verify before applying.

## Workspaces vs Directory-Based Environments

**Workspaces** — lightweight isolation when code is identical across environments:

```bash
terraform workspace new staging
terraform workspace select staging
terraform apply -var-file="staging.tfvars"
```

**Directory-based** — when environments differ structurally:

```
environments/
├── dev/      (main.tf + terraform.tfvars)
├── staging/  (main.tf + terraform.tfvars)
└── prod/     (main.tf + terraform.tfvars)
```

Prefer directory-based for production. Each directory has its own state and backend config.

## Testing

### Native terraform test (1.6+)

Write `.tftest.hcl` files in a `tests/` directory:

```hcl
run "creates_vpc" {
  command = plan
  variables {
    cidr_block  = "10.0.0.0/16"
    environment = "test"
  }
  assert {
    condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR does not match input"
  }
}
```

### Mock Providers (1.7+)

Test without real cloud calls:

```hcl
mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-bucket" }
  }
}

run "bucket_name_set" {
  variables { bucket_name = "my-bucket" }
  assert {
    condition     = aws_s3_bucket.main.bucket == "my-bucket"
    error_message = "Bucket name mismatch"
  }
}
```

Run: `terraform test`. Filter: `terraform test -filter=tests/vpc.tftest.hcl`.

### Terratest (Go)

```go
func TestVpcModule(t *testing.T) {
    opts := &terraform.Options{
        TerraformDir: "../modules/vpc",
        Vars: map[string]interface{}{"cidr_block": "10.0.0.0/16"},
    }
    defer terraform.Destroy(t, opts)
    terraform.InitAndApply(t, opts)
    vpcID := terraform.Output(t, opts, "vpc_id")
    assert.NotEmpty(t, vpcID)
}
```

## CI/CD Pipeline

1. **On PR** — `terraform fmt -check`, `terraform validate`, `terraform plan -out=tfplan`.
2. **On merge** — `terraform apply tfplan` using saved plan artifact.
3. **Scheduled** — `terraform plan` for drift detection; alert on differences.

Set `TF_IN_AUTOMATION=1` and `-input=false` in CI. Store plan files as artifacts for audit.

## Provider Configuration and Dependency Injection

Define providers only in root. Pass to child modules explicitly:

```hcl
provider "aws" {
  region = "us-east-1"
  alias  = "primary"
}

provider "aws" {
  region = "eu-west-1"
  alias  = "secondary"
}

module "primary_vpc" {
  source    = "./modules/vpc"
  providers = { aws = aws.primary }
}

module "dr_vpc" {
  source    = "./modules/vpc"
  providers = { aws = aws.secondary }
}
```

In child modules, declare required providers without configuration:

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}
```

## Data Sources and Dynamic Blocks

Reference existing resources with data sources:

```hcl
data "aws_caller_identity" "current" {}
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

Use dynamic blocks for repeatable nested structures:

```hcl
resource "aws_security_group" "main" {
  name   = "${var.name}-sg"
  vpc_id = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }
}
```

Avoid deeply nested dynamic blocks — split into separate resources if complex.

## Moved Blocks and Refactoring

Use `moved` blocks to rename or relocate resources without destroy/recreate:

```hcl
moved {
  from = aws_instance.web
  to   = aws_instance.application
}

moved {
  from = module.old_name
  to   = module.new_name
}
```

Use `removed` blocks (1.7+) to drop resources from state without destroying:

```hcl
removed {
  from = aws_instance.legacy
  lifecycle { destroy = false }
}
```

Apply `moved` blocks in one release, then remove them in the next.

## Common Module Patterns

### VPC Module

```hcl
module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~> 5.0"
  name               = "${var.project}-${var.environment}"
  cidr               = var.vpc_cidr
  azs                = var.availability_zones
  private_subnets    = var.private_subnet_cidrs
  public_subnets     = var.public_subnet_cidrs
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "prod"
  tags               = var.tags
}
```

### EKS Module

```hcl
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"
  cluster_name    = "${var.project}-${var.environment}"
  cluster_version = "1.29"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  enable_irsa     = true
  eks_managed_node_groups = {
    default = {
      instance_types = ["m5.large"]
      min_size       = var.environment == "prod" ? 3 : 1
      max_size       = var.environment == "prod" ? 10 : 3
    }
  }
}
```

## Quick Reference

| Practice | Do | Don't |
|---|---|---|
| Providers | Define in root only | Configure in child modules |
| Variables | Type + validate + describe | Use `any` type |
| Outputs | Describe every output | Expose internal details |
| Versions | Pin with `~>` constraints | Use unversioned sources |
| State | Remote backend + locking | Local state in production |
| Testing | `terraform test` + CI plan | Skip validation |
| Naming | `terraform-{provider}-{name}` | Ambiguous names |
| Modules | <20 resources, single purpose | Monolithic modules |

## Enrichment Resources

### References

| File | Description |
|------|-------------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Module composition, factories, check blocks, ephemeral resources, provider functions, Stacks, monorepo vs polyrepo |
| [`references/troubleshooting.md`](references/troubleshooting.md) | State locks, drift, provider conflicts, circular deps, import/moved gotchas, performance, timeouts |
| [`references/testing-guide.md`](references/testing-guide.md) | Terraform test framework, mock providers, Terratest patterns |

### Scripts

| File | Description |
|------|-------------|
| [`scripts/scaffold-module.sh`](scripts/scaffold-module.sh) | Generate module with standard layout. Usage: `./scaffold-module.sh <name> [provider]` |
| [`scripts/validate-module.sh`](scripts/validate-module.sh) | Validate: fmt, init, validate, tflint, terraform-docs, test, security scan. Usage: `./validate-module.sh [dir]` |
| [`scripts/publish-module.sh`](scripts/publish-module.sh) | Module publishing workflow for registries |

### Assets

| File | Description |
|------|-------------|
| [`assets/vpc-module/`](assets/vpc-module/) | Complete VPC module: public/private subnets, NAT gateways, flow logs, for_each patterns |
| [`assets/github-actions.yml`](assets/github-actions.yml) | CI/CD: plan on PR with comments, apply on merge, daily drift detection |
| [`assets/terragrunt.hcl`](assets/terragrunt.hcl) | Terragrunt DRY template: hierarchy, remote state, dependencies, hooks |
| [`assets/module-template/`](assets/module-template/) | Basic module template |
| [`assets/github-actions-ci.yml`](assets/github-actions-ci.yml) | Lightweight CI-only workflow |
| [`assets/terrafile.hcl`](assets/terrafile.hcl) | Terrafile for module dependencies |
| [`assets/.tflint.hcl`](assets/.tflint.hcl) | TFLint configuration |
<!-- tested: pass -->
