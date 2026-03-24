# Advanced Terraform Module Patterns

## Table of Contents

- [Module Composition Architectures](#module-composition-architectures)
  - [Root and Child Module Relationship](#root-and-child-module-relationship)
  - [Facade Pattern](#facade-pattern)
  - [Factory Pattern](#factory-pattern)
  - [Inverted Module Pattern](#inverted-module-pattern)
- [Dynamic Backend Configuration](#dynamic-backend-configuration)
  - [Backend Partial Configuration](#backend-partial-configuration)
  - [Cloud Block (TFC/TFE)](#cloud-block-tfctfe)
  - [Backend Migration](#backend-migration)
- [Complex Variable Validation](#complex-variable-validation)
  - [Multi-Rule Validation](#multi-rule-validation)
  - [Cross-Variable Validation with Locals](#cross-variable-validation-with-locals)
  - [Regex and Format Validation](#regex-and-format-validation)
  - [Complex Object Validation](#complex-object-validation)
  - [Custom Condition Blocks (Preconditions/Postconditions)](#custom-condition-blocks-preconditionspostconditions)
- [Provider Aliasing and Configuration](#provider-aliasing-and-configuration)
  - [Multi-Region Deployments](#multi-region-deployments)
  - [Multi-Account Deployments](#multi-account-deployments)
  - [Provider Configuration in Child Modules](#provider-configuration-in-child-modules)
  - [Dynamic Provider Selection](#dynamic-provider-selection)
- [Moved Blocks](#moved-blocks)
  - [Renaming Resources](#renaming-resources)
  - [Moving into Modules](#moving-into-modules)
  - [Moving Between Modules](#moving-between-modules)
  - [Refactoring count to for_each](#refactoring-count-to-for_each)
- [Import Blocks](#import-blocks)
  - [Basic Import](#basic-import)
  - [Import with for_each](#import-with-for_each)
  - [Generating Configuration from Import](#generating-configuration-from-import)
- [State Migration Strategies](#state-migration-strategies)
  - [Splitting a Monolith State](#splitting-a-monolith-state)
  - [Merging States](#merging-states)
  - [Cross-Backend Migration](#cross-backend-migration)
  - [State File Manipulation Safety](#state-file-manipulation-safety)
- [Advanced for_each and count Patterns](#advanced-for_each-and-count-patterns)
  - [Conditional Resource Creation](#conditional-resource-creation)
  - [Nested for_each with flatten](#nested-for_each-with-flatten)
  - [Dynamic Blocks](#dynamic-blocks)
- [Module Dependency Injection](#module-dependency-injection)
  - [Passing Entire Resources](#passing-entire-resources)
  - [Dependency Inversion](#dependency-inversion)

---

## Module Composition Architectures

### Root and Child Module Relationship

The root module is the top-level configuration that Terraform runs directly. Child modules are reusable components called from root (or other child) modules. Understanding their contract is foundational.

**Root module responsibilities:**
- Configure providers and backends
- Wire child modules together via outputs → inputs
- Define environment-specific values
- Hold no reusable logic (it is the consumer)

**Child module responsibilities:**
- Accept all configuration via variables
- Never declare `provider` blocks (only `required_providers` with `configuration_aliases`)
- Expose meaningful outputs
- Be stateless — no backend configuration

```hcl
# Root module — environments/prod/main.tf
terraform {
  backend "s3" {
    bucket = "prod-tf-state"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Environment = "prod", ManagedBy = "terraform" }
  }
}

module "networking" {
  source       = "../../modules/networking"
  vpc_cidr     = "10.0.0.0/16"
  environment  = "prod"
  az_count     = 3
}

module "application" {
  source      = "../../modules/application"
  vpc_id      = module.networking.vpc_id
  subnet_ids  = module.networking.private_subnet_ids
  environment = "prod"
}
```

### Facade Pattern

A facade module wraps multiple child modules into a single, simplified interface. This hides internal wiring from consumers.

```hcl
# modules/platform/main.tf — Facade
variable "environment" { type = string }
variable "vpc_cidr" { type = string }
variable "app_config" {
  type = object({
    instance_type = string
    min_size      = number
    max_size      = number
  })
}

module "network" {
  source      = "../network"
  cidr_block  = var.vpc_cidr
  environment = var.environment
}

module "security" {
  source      = "../security"
  vpc_id      = module.network.vpc_id
  environment = var.environment
}

module "compute" {
  source          = "../compute"
  vpc_id          = module.network.vpc_id
  subnet_ids      = module.network.private_subnet_ids
  security_groups = module.security.app_sg_ids
  instance_type   = var.app_config.instance_type
  min_size        = var.app_config.min_size
  max_size        = var.app_config.max_size
}

output "load_balancer_dns" {
  value = module.compute.lb_dns_name
}

output "vpc_id" {
  value = module.network.vpc_id
}
```

Consumer usage is greatly simplified:

```hcl
module "platform" {
  source      = "./modules/platform"
  environment = "prod"
  vpc_cidr    = "10.0.0.0/16"
  app_config  = {
    instance_type = "m5.large"
    min_size      = 3
    max_size      = 10
  }
}
```

### Factory Pattern

The factory pattern creates multiple instances of a complex resource group from a map of specifications. It combines `for_each` at the module level with rich object variables.

```hcl
# modules/microservice-factory/variables.tf
variable "services" {
  type = map(object({
    image          = string
    cpu            = number
    memory         = number
    port           = number
    desired_count  = optional(number, 2)
    health_path    = optional(string, "/health")
    environment    = optional(map(string), {})
    secrets        = optional(list(string), [])
    autoscaling    = optional(object({
      min_capacity = number
      max_capacity = number
      cpu_target   = optional(number, 70)
    }), null)
  }))
  description = "Map of service name to service configuration."
}

# modules/microservice-factory/main.tf
module "service" {
  source   = "../ecs-service"
  for_each = var.services

  name          = each.key
  image         = each.value.image
  cpu           = each.value.cpu
  memory        = each.value.memory
  port          = each.value.port
  desired_count = each.value.desired_count
  health_path   = each.value.health_path
  environment   = each.value.environment
  secrets       = each.value.secrets
  autoscaling   = each.value.autoscaling
}
```

Consumer usage:

```hcl
module "services" {
  source = "./modules/microservice-factory"

  services = {
    api = {
      image  = "myapp/api:v1.2.0"
      cpu    = 512
      memory = 1024
      port   = 8080
      autoscaling = { min_capacity = 2, max_capacity = 20 }
    }
    worker = {
      image         = "myapp/worker:v1.2.0"
      cpu           = 1024
      memory        = 2048
      port          = 9090
      desired_count = 3
      environment   = { QUEUE_URL = aws_sqs_queue.work.url }
    }
  }
}
```

### Inverted Module Pattern

Instead of a module creating a resource, the module receives a reference to an already-created resource and configures it further. Useful for policies, IAM attachments, and configurations that augment existing infrastructure.

```hcl
# modules/s3-hardening/variables.tf
variable "bucket_id" {
  type        = string
  description = "ID of an existing S3 bucket to harden."
}

variable "deny_unencrypted" {
  type    = bool
  default = true
}

# modules/s3-hardening/main.tf
resource "aws_s3_bucket_versioning" "this" {
  bucket = var.bucket_id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = var.bucket_id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = var.bucket_id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

---

## Dynamic Backend Configuration

### Backend Partial Configuration

Terraform backends don't support variables, but you can use **partial configuration** with `-backend-config` flags or files:

```hcl
# backend.tf
terraform {
  backend "s3" {
    # Only static values here; dynamic values from -backend-config
    encrypt = true
  }
}
```

```bash
# Per-environment backend config files
# config/prod.backend.hcl
bucket         = "prod-tf-state"
key            = "prod/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "prod-tf-lock"

# Initialize with:
terraform init -backend-config=config/prod.backend.hcl
```

Or pass individual values:

```bash
terraform init \
  -backend-config="bucket=prod-tf-state" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=us-east-1"
```

### Cloud Block (TFC/TFE)

For Terraform Cloud / Enterprise, use the `cloud` block (replaces `backend "remote"`):

```hcl
terraform {
  cloud {
    organization = "my-org"

    workspaces {
      tags = ["networking", "prod"]
      # OR use name for a single workspace:
      # name = "networking-prod"
    }
  }
}
```

Use the `TF_CLOUD_ORGANIZATION` and `TF_WORKSPACE` environment variables for dynamic configuration:

```bash
export TF_CLOUD_ORGANIZATION="my-org"
export TF_WORKSPACE="networking-prod"
terraform init
```

### Backend Migration

When migrating between backends:

```bash
# 1. Update backend configuration in code
# 2. Run init with migration flag
terraform init -migrate-state

# For reconfiguration (no state copy):
terraform init -reconfigure
```

---

## Complex Variable Validation

### Multi-Rule Validation

Terraform 1.9+ supports multiple validation blocks per variable:

```hcl
variable "instance_type" {
  type = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "Instance type must match format like 't3.micro' or 'm5.large'."
  }

  validation {
    condition     = !contains(["t2.nano", "t2.micro"], var.instance_type)
    error_message = "t2.nano and t2.micro are not allowed — use t3 or newer."
  }
}
```

### Cross-Variable Validation with Locals

Variables can only reference themselves in `validation` blocks. For cross-variable checks, use `locals` with `precondition`:

```hcl
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "desired_capacity" { type = number }

locals {
  _validate_capacity = (
    var.desired_capacity >= var.min_size &&
    var.desired_capacity <= var.max_size
  )
}

resource "null_resource" "validate" {
  lifecycle {
    precondition {
      condition     = local._validate_capacity
      error_message = "desired_capacity must be between min_size and max_size."
    }
  }
}
```

Or with a `check` block (Terraform 1.5+):

```hcl
check "capacity_validation" {
  assert {
    condition     = var.desired_capacity >= var.min_size && var.desired_capacity <= var.max_size
    error_message = "desired_capacity (${var.desired_capacity}) must be between min_size (${var.min_size}) and max_size (${var.max_size})."
  }
}
```

### Regex and Format Validation

```hcl
variable "bucket_name" {
  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be 3-63 chars, lowercase, numbers, hyphens, dots."
  }
}

variable "cidr_block" {
  type = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "Must be a valid CIDR notation (e.g., 10.0.0.0/16)."
  }
}

variable "email" {
  type = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.email))
    error_message = "Must be a valid email address."
  }
}
```

### Complex Object Validation

```hcl
variable "database" {
  type = object({
    engine         = string
    engine_version = string
    instance_class = string
    storage_gb     = number
    multi_az       = bool
    backup_retention_days = optional(number, 7)
  })

  validation {
    condition     = contains(["postgres", "mysql", "mariadb"], var.database.engine)
    error_message = "Engine must be postgres, mysql, or mariadb."
  }

  validation {
    condition     = var.database.storage_gb >= 20 && var.database.storage_gb <= 65536
    error_message = "Storage must be between 20 and 65536 GB."
  }

  validation {
    condition     = var.database.backup_retention_days >= 1 && var.database.backup_retention_days <= 35
    error_message = "Backup retention must be between 1 and 35 days."
  }
}
```

### Custom Condition Blocks (Preconditions/Postconditions)

```hcl
resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = var.instance_type

  lifecycle {
    precondition {
      condition     = data.aws_ami.selected.architecture == "x86_64"
      error_message = "AMI must be x86_64 architecture."
    }

    postcondition {
      condition     = self.public_ip != ""
      error_message = "Instance must have a public IP assigned."
    }
  }
}

data "aws_ami" "selected" {
  most_recent = true
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}
```

---

## Provider Aliasing and Configuration

### Multi-Region Deployments

```hcl
# Root module
provider "aws" {
  region = "us-east-1"
  alias  = "primary"
}

provider "aws" {
  region = "eu-west-1"
  alias  = "dr"
}

module "primary_infra" {
  source = "./modules/regional-infra"
  providers = {
    aws = aws.primary
  }
  environment = "prod"
  region_name = "us-east-1"
}

module "dr_infra" {
  source = "./modules/regional-infra"
  providers = {
    aws = aws.dr
  }
  environment = "prod"
  region_name = "eu-west-1"
}
```

### Multi-Account Deployments

```hcl
provider "aws" {
  region = "us-east-1"
  alias  = "security"
  assume_role {
    role_arn = "arn:aws:iam::${var.security_account_id}:role/TerraformRole"
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "workload"
  assume_role {
    role_arn = "arn:aws:iam::${var.workload_account_id}:role/TerraformRole"
  }
}

module "guardduty" {
  source    = "./modules/guardduty"
  providers = { aws = aws.security }
}

module "application" {
  source    = "./modules/application"
  providers = { aws = aws.workload }
}
```

### Provider Configuration in Child Modules

Child modules must **never** contain `provider` blocks. They declare what they need via `configuration_aliases`:

```hcl
# modules/cross-region-replica/versions.tf
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0"
      configuration_aliases = [aws.source, aws.destination]
    }
  }
}

# modules/cross-region-replica/main.tf
resource "aws_s3_bucket" "source" {
  provider = aws.source
  bucket   = "${var.name}-source"
}

resource "aws_s3_bucket" "replica" {
  provider = aws.destination
  bucket   = "${var.name}-replica"
}
```

### Dynamic Provider Selection

For modules that may or may not need an aliased provider:

```hcl
# Root module — pass the same provider twice if no alias needed
module "single_region" {
  source = "./modules/cross-region-replica"
  providers = {
    aws.source      = aws
    aws.destination = aws
  }
}
```

---

## Moved Blocks

`moved` blocks (Terraform 1.1+) enable safe refactoring without destroying and recreating resources.

### Renaming Resources

```hcl
# Old: resource "aws_instance" "web"
# New: resource "aws_instance" "application"

moved {
  from = aws_instance.web
  to   = aws_instance.application
}

resource "aws_instance" "application" {
  ami           = var.ami_id
  instance_type = var.instance_type
}
```

### Moving into Modules

```hcl
# Previously a root-level resource, now inside a module
moved {
  from = aws_vpc.main
  to   = module.networking.aws_vpc.main
}

module "networking" {
  source = "./modules/networking"
}
```

### Moving Between Modules

```hcl
moved {
  from = module.old_network.aws_vpc.this
  to   = module.new_network.aws_vpc.this
}
```

### Refactoring count to for_each

```hcl
# Old: resource "aws_subnet" "private" { count = 3 }
# New: resource "aws_subnet" "private" { for_each = toset(var.azs) }

moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["us-east-1a"]
}

moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["us-east-1b"]
}

moved {
  from = aws_subnet.private[2]
  to   = aws_subnet.private["us-east-1c"]
}
```

After a successful apply, `moved` blocks can remain indefinitely (they are no-ops once the state matches) or be removed in a later release.

---

## Import Blocks

`import` blocks (Terraform 1.5+) bring existing infrastructure under Terraform management declaratively.

### Basic Import

```hcl
import {
  to = aws_s3_bucket.legacy
  id = "my-legacy-bucket-name"
}

resource "aws_s3_bucket" "legacy" {
  bucket = "my-legacy-bucket-name"
  # Remaining config must match the real resource
}
```

### Import with for_each

```hcl
locals {
  existing_buckets = {
    logs    = "company-logs-prod"
    backups = "company-backups-prod"
    assets  = "company-assets-prod"
  }
}

import {
  for_each = local.existing_buckets
  to       = aws_s3_bucket.managed[each.key]
  id       = each.value
}

resource "aws_s3_bucket" "managed" {
  for_each = local.existing_buckets
  bucket   = each.value
}
```

### Generating Configuration from Import

Terraform 1.5+ can generate configuration stubs:

```bash
# Generate config for imported resources
terraform plan -generate-config-out=generated.tf
```

This creates `generated.tf` with resource blocks matching the real infrastructure. Review and refine the generated code before committing.

---

## State Migration Strategies

### Splitting a Monolith State

When a state file grows too large, split it into smaller states:

```bash
# 1. Identify resources to extract
terraform state list | grep "module.networking"

# 2. In the NEW project, import each resource
cd ../networking
terraform import aws_vpc.main vpc-abc123
terraform import aws_subnet.private[0] subnet-def456

# 3. In the OLD project, remove the resources from state
cd ../monolith
terraform state rm module.networking.aws_vpc.main
terraform state rm module.networking.aws_subnet.private[0]

# 4. Verify both states
terraform plan  # Should show no changes in both projects
```

### Merging States

Use `terraform state mv` with the `-state` and `-state-out` flags:

```bash
# Pull states locally
terraform state pull > source.tfstate
cd ../target && terraform state pull > target.tfstate

# Move resources between state files
terraform state mv \
  -state=source.tfstate \
  -state-out=target.tfstate \
  aws_instance.web aws_instance.web

# Push updated state
cd ../target && terraform state push target.tfstate
```

### Cross-Backend Migration

```bash
# 1. Update backend configuration in .tf files
# 2. Run init with migration
terraform init -migrate-state

# If prompted, confirm the state copy
# Terraform copies state from old backend to new backend
```

### State File Manipulation Safety

**Always follow these rules:**

1. **Lock state before manipulation:** `terraform force-unlock LOCK_ID` only when necessary
2. **Back up before surgery:** `terraform state pull > backup-$(date +%s).tfstate`
3. **Use `terraform state` commands**, never edit JSON directly
4. **Run `terraform plan` after any state change** to verify no unexpected diffs
5. **Work in a maintenance window** — state operations can conflict with other runs

---

## Advanced for_each and count Patterns

### Conditional Resource Creation

```hcl
variable "create_dns_record" {
  type    = bool
  default = true
}

resource "aws_route53_record" "app" {
  count = var.create_dns_record ? 1 : 0

  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name    = aws_lb.app.dns_name
    zone_id = aws_lb.app.zone_id
  }
}

# Reference with conditional:
output "dns_name" {
  value = var.create_dns_record ? aws_route53_record.app[0].fqdn : null
}

# Better with one():
output "dns_name_v2" {
  value = one(aws_route53_record.app[*].fqdn)
}
```

### Nested for_each with flatten

```hcl
variable "subnets" {
  type = map(object({
    cidr_blocks = list(string)
  }))
  default = {
    web = { cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24"] }
    app = { cidr_blocks = ["10.0.10.0/24", "10.0.11.0/24"] }
  }
}

locals {
  subnet_flat = flatten([
    for tier, config in var.subnets : [
      for idx, cidr in config.cidr_blocks : {
        key  = "${tier}-${idx}"
        tier = tier
        cidr = cidr
        az   = data.aws_availability_zones.available.names[idx]
      }
    ]
  ])
  subnet_map = { for s in local.subnet_flat : s.key => s }
}

resource "aws_subnet" "this" {
  for_each          = local.subnet_map
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = {
    Name = each.key
    Tier = each.value.tier
  }
}
```

### Dynamic Blocks

```hcl
variable "ingress_rules" {
  type = list(object({
    port        = number
    protocol    = string
    cidr_blocks = list(string)
    description = optional(string, "")
  }))
}

resource "aws_security_group" "app" {
  name   = "app-sg"
  vpc_id = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      description = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## Module Dependency Injection

### Passing Entire Resources

Instead of passing individual attributes, pass entire resource references using complex objects:

```hcl
# modules/app/variables.tf
variable "vpc" {
  type = object({
    id                 = string
    private_subnet_ids = list(string)
    public_subnet_ids  = list(string)
  })
  description = "VPC configuration — accepts module.network output object."
}

# Root module
module "network" { source = "./modules/network" }

module "app" {
  source = "./modules/app"
  vpc    = module.network  # Pass the entire output set
}
```

The network module must expose a matching output structure:

```hcl
# modules/network/outputs.tf
output "id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
```

### Dependency Inversion

Create an interface-like variable that multiple implementations can satisfy:

```hcl
# modules/app/variables.tf
variable "notification_endpoint" {
  type = object({
    arn  = string
    type = string  # "sns" | "sqs" | "lambda"
  })
  description = "Where to send notifications — any service that accepts messages."
}

# Root module — swap implementations without changing the app module
module "app" {
  source = "./modules/app"
  notification_endpoint = {
    arn  = aws_sns_topic.alerts.arn
    type = "sns"
  }
}
```
