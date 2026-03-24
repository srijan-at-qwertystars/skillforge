# Terraform Module Troubleshooting Guide

## Table of Contents

- [Provider Errors](#provider-errors)
  - [Provider Inheritance Failures](#provider-inheritance-failures)
  - [Provider Version Conflicts](#provider-version-conflicts)
  - [Configuration Aliases Mismatch](#configuration-aliases-mismatch)
- [Circular Dependencies](#circular-dependencies)
  - [Identifying Cycles](#identifying-cycles)
  - [Breaking Dependency Cycles](#breaking-dependency-cycles)
  - [Module-Level Circular References](#module-level-circular-references)
- [Count and for_each Limitations](#count-and-for_each-limitations)
  - [Unknown Values in for_each](#unknown-values-in-for_each)
  - [Count Cannot Be Computed](#count-cannot-be-computed)
  - [Converting Between count and for_each](#converting-between-count-and-for_each)
  - [Module-Level for_each Restrictions](#module-level-for_each-restrictions)
- [State Locking Issues](#state-locking-issues)
  - [Lock Stuck After Crash](#lock-stuck-after-crash)
  - [DynamoDB Lock Errors](#dynamodb-lock-errors)
  - [Concurrent State Operations](#concurrent-state-operations)
- [State Drift and Corruption](#state-drift-and-corruption)
  - [Detecting Drift](#detecting-drift)
  - [Recovering from State Corruption](#recovering-from-state-corruption)
  - [Resource Exists But Not in State](#resource-exists-but-not-in-state)
  - [Resource in State But Deleted](#resource-in-state-but-deleted)
- [Init and Backend Errors](#init-and-backend-errors)
  - [Backend Configuration Changed](#backend-configuration-changed)
  - [Module Source Resolution Failures](#module-source-resolution-failures)
  - [Registry Authentication Issues](#registry-authentication-issues)
- [Plan and Apply Errors](#plan-and-apply-errors)
  - [Inconsistent Plan](#inconsistent-plan)
  - [Resource Already Exists](#resource-already-exists)
  - [Timeout Errors](#timeout-errors)
  - [API Rate Limiting](#api-rate-limiting)
- [Variable and Type Errors](#variable-and-type-errors)
  - [Type Constraint Mismatches](#type-constraint-mismatches)
  - [Optional Attribute Defaults](#optional-attribute-defaults)
  - [Sensitive Value Exposure](#sensitive-value-exposure)
- [Debugging with TF_LOG](#debugging-with-tf_log)
  - [Log Levels](#log-levels)
  - [Provider-Specific Logging](#provider-specific-logging)
  - [Log File Output](#log-file-output)
  - [Reading Debug Logs](#reading-debug-logs)
- [State Surgery](#state-surgery)
  - [terraform state mv](#terraform-state-mv)
  - [terraform state rm](#terraform-state-rm)
  - [terraform state import](#terraform-state-import)
  - [terraform state replace-provider](#terraform-state-replace-provider)
  - [Advanced State Manipulation](#advanced-state-manipulation)
- [Performance Issues](#performance-issues)
  - [Slow Plans with Large State](#slow-plans-with-large-state)
  - [Reducing Provider API Calls](#reducing-provider-api-calls)
  - [Parallelism Tuning](#parallelism-tuning)
- [Common Error Messages Reference](#common-error-messages-reference)

---

## Provider Errors

### Provider Inheritance Failures

**Error:**
```
Error: No configuration for provider "aws.west"

Module "replica" depends on provider configuration "aws.west", but that
provider configuration was not passed into the module.
```

**Cause:** The child module expects a provider alias that the root module didn't pass.

**Fix:** Explicitly pass all required providers using the `providers` argument:

```hcl
# Root module
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "west"
  region = "us-west-2"
}

module "replica" {
  source = "./modules/replica"
  providers = {
    aws.primary = aws
    aws.replica = aws.west
  }
}
```

The child module must declare:

```hcl
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.replica]
    }
  }
}
```

### Provider Version Conflicts

**Error:**
```
Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider
hashicorp/aws: locked provider registry.terraform.io/hashicorp/aws 4.67.0
does not match configured version constraint ~> 5.0.
```

**Fix:** Update the lock file:

```bash
# Delete the lock file and re-init
rm .terraform.lock.hcl
terraform init -upgrade

# Or upgrade specific provider
terraform init -upgrade=hashicorp/aws
```

If different modules need different provider versions (rare — usually a design problem):

```bash
# Check which modules require which versions
terraform providers
```

### Configuration Aliases Mismatch

**Error:**
```
Error: Module module.foo has invalid provider configuration

The module module.foo requires provider aws.special, which is not
configured as one of the allowed providers.
```

**Cause:** The `providers` map in the module call doesn't match the `configuration_aliases` in the module's `required_providers`.

**Fix:** Ensure the keys in `providers` match exactly:

```hcl
# Child module declares:
# configuration_aliases = [aws.primary, aws.secondary]

# Root must provide BOTH aliases:
module "foo" {
  source = "./modules/foo"
  providers = {
    aws.primary   = aws
    aws.secondary = aws.west  # Must match the alias names
  }
}
```

---

## Circular Dependencies

### Identifying Cycles

**Error:**
```
Error: Cycle: aws_security_group.a, aws_security_group.b
```

**Cause:** Resource A references Resource B and Resource B references Resource A.

```hcl
# BAD — circular reference
resource "aws_security_group" "a" {
  ingress {
    security_groups = [aws_security_group.b.id]
  }
}

resource "aws_security_group" "b" {
  ingress {
    security_groups = [aws_security_group.a.id]
  }
}
```

### Breaking Dependency Cycles

**Fix:** Use separate `aws_security_group_rule` resources:

```hcl
resource "aws_security_group" "a" {
  name = "sg-a"
}

resource "aws_security_group" "b" {
  name = "sg-b"
}

resource "aws_security_group_rule" "a_from_b" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.b.id
  security_group_id        = aws_security_group.a.id
}

resource "aws_security_group_rule" "b_from_a" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.a.id
  security_group_id        = aws_security_group.b.id
}
```

### Module-Level Circular References

**Error:**
```
Error: Cycle: module.a, module.b
```

**Cause:** Module A's input depends on Module B's output and vice versa.

**Fix options:**
1. Merge the modules (they're too tightly coupled to be separate)
2. Use data sources to read shared state
3. Break the cycle with `terraform_remote_state`
4. Introduce a third module that both depend on

```hcl
# Instead of A <-> B, use A -> C <- B
module "shared" { source = "./modules/shared" }
module "a" {
  source   = "./modules/a"
  shared   = module.shared
}
module "b" {
  source   = "./modules/b"
  shared   = module.shared
}
```

---

## Count and for_each Limitations

### Unknown Values in for_each

**Error:**
```
Error: Invalid for_each argument

The "for_each" set includes values derived from resource attributes
that cannot be determined until apply, and so Terraform cannot determine
the full set of keys that will identify the instances of this resource.
```

**Cause:** `for_each` keys must be known at plan time. You cannot use values that come from resources not yet created.

**Fix options:**

1. Use static values or variables instead of computed values:

```hcl
# BAD — for_each depends on a resource output
resource "aws_subnet" "this" {
  for_each = toset(aws_vpc.main.availability_zones)  # Unknown at plan!
}

# GOOD — use a variable or data source
data "aws_availability_zones" "available" { state = "available" }

resource "aws_subnet" "this" {
  for_each          = toset(slice(data.aws_availability_zones.available.names, 0, 3))
  availability_zone = each.value
}
```

2. Split into two applies (apply the dependency first, then the dependent resources)

3. Use `-target` to create the dependency first:
```bash
terraform apply -target=aws_vpc.main
terraform apply
```

### Count Cannot Be Computed

**Error:**
```
Error: Invalid count argument

The "count" value depends on resource attributes that cannot be determined
until apply.
```

**Same root cause as for_each.** Fix by using known values:

```hcl
# BAD
resource "aws_instance" "app" {
  count = length(module.network.subnet_ids)  # May be unknown
}

# GOOD — use a variable
variable "instance_count" { type = number }

resource "aws_instance" "app" {
  count = var.instance_count
}
```

### Converting Between count and for_each

When refactoring from `count` to `for_each`, resources get destroyed and recreated unless you use `moved` blocks:

```hcl
# Old: resource "aws_subnet" "private" { count = 3 }
# New: resource "aws_subnet" "private" { for_each = var.azs_map }

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

### Module-Level for_each Restrictions

Module `for_each` and `count` have the same plan-time-known restriction. Additionally, you cannot use `for_each` with a module that uses `depends_on`.

```hcl
# This will fail if var.services depends on another resource's output
module "service" {
  source   = "./modules/service"
  for_each = var.services  # Must be known at plan time
}
```

---

## State Locking Issues

### Lock Stuck After Crash

**Error:**
```
Error: Error locking state: Error acquiring the state lock: ConditionalCheckFailedException

Lock Info:
  ID:        a1b2c3d4-e5f6-7890-abcd-ef1234567890
  Path:      terraform-state/prod/terraform.tfstate
  Operation: OperationTypeApply
  Who:       user@hostname
  Version:   1.9.0
  Created:   2024-01-15 10:30:00 UTC
```

**Fix:** Force-unlock after verifying no other operation is running:

```bash
# CRITICAL: Verify no one else is running terraform first!
terraform force-unlock a1b2c3d4-e5f6-7890-abcd-ef1234567890
```

### DynamoDB Lock Errors

**Error:**
```
Error: Error acquiring the state lock: AccessDeniedException:
User is not authorized to perform: dynamodb:PutItem
```

**Fix:** Ensure the IAM role/user has these DynamoDB permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:DeleteItem"
  ],
  "Resource": "arn:aws:dynamodb:*:*:table/tf-lock"
}
```

Also verify the DynamoDB table exists and has `LockID` as the partition key (type String).

### Concurrent State Operations

**Prevention:** Never run multiple Terraform commands against the same state simultaneously. Use CI/CD pipelines with queue/lock mechanisms. If using Terraform Cloud, it handles this automatically with run queues.

---

## State Drift and Corruption

### Detecting Drift

```bash
# Detect drift by running a plan
terraform plan -detailed-exitcode
# Exit code 0 = no changes, 1 = error, 2 = changes detected

# For scheduled drift detection:
terraform plan -detailed-exitcode -out=drift.tfplan
echo $?  # Check exit code
```

### Recovering from State Corruption

```bash
# 1. Pull the state (if accessible)
terraform state pull > corrupted.tfstate

# 2. Check for a backup in the S3 bucket
aws s3api list-object-versions --bucket my-tf-state --prefix prod/terraform.tfstate

# 3. Restore a previous version
aws s3api get-object \
  --bucket my-tf-state \
  --key prod/terraform.tfstate \
  --version-id "VERSION_ID" \
  restored.tfstate

# 4. Push the restored state
terraform state push restored.tfstate
```

**Always enable versioning on the S3 state bucket.**

### Resource Exists But Not in State

The resource was created outside Terraform or state was lost:

```bash
# Import the existing resource
terraform import aws_s3_bucket.logs my-logs-bucket

# Or use import blocks (Terraform 1.5+):
import {
  to = aws_s3_bucket.logs
  id = "my-logs-bucket"
}
```

### Resource in State But Deleted

The resource was deleted outside Terraform:

```bash
# Option 1: Let Terraform recreate it
terraform apply  # It will create the missing resource

# Option 2: Remove from state if you don't want it anymore
terraform state rm aws_s3_bucket.old_logs

# Option 3: Refresh state to detect deletions
terraform apply -refresh-only
```

---

## Init and Backend Errors

### Backend Configuration Changed

**Error:**
```
Error: Backend configuration changed

A change in the backend configuration has been detected, which may require
migrating existing state.
```

**Fix:**
```bash
# Migrate state to new backend
terraform init -migrate-state

# Or reconfigure without migrating (fresh start)
terraform init -reconfigure
```

### Module Source Resolution Failures

**Error:**
```
Error: Failed to download module

Could not download module "vpc" (main.tf:5) source code from
"git::https://github.com/org/terraform-modules.git?ref=v2.0.0":
error downloading 'https://github.com/org/terraform-modules.git':
/usr/bin/git exited with 128: fatal: could not read Username
```

**Fix options:**

```bash
# For SSH-based git sources:
export GIT_SSH_COMMAND="ssh -i ~/.ssh/terraform_key -o StrictHostKeyChecking=no"
terraform init

# For HTTPS with token:
git config --global url."https://oauth2:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
terraform init

# For private registries:
cat > ~/.terraformrc << EOF
credentials "app.terraform.io" {
  token = "your-api-token"
}
EOF
```

### Registry Authentication Issues

**Error:**
```
Error: Failed to query available provider packages

Could not retrieve the list of available versions for provider
myorg/custom: provider registry registry.terraform.io does not have a
provider named registry.terraform.io/myorg/custom
```

**Fix:** Verify the provider source and configure credentials:

```hcl
terraform {
  required_providers {
    custom = {
      source  = "app.terraform.io/myorg/custom"
      version = "~> 1.0"
    }
  }
}
```

---

## Plan and Apply Errors

### Inconsistent Plan

**Error:**
```
Error: Provider produced inconsistent result after apply

When applying changes to aws_instance.app, provider "aws" produced an
unexpected new value: .tags_all: was map[], but now map["Environment":"prod"].
```

**Cause:** The provider's API returned values different from what the plan predicted. Often caused by `default_tags` in the AWS provider or server-side defaults.

**Fix:** Usually safe to re-run `terraform apply`. If persistent, explicitly set the attributes the provider is defaulting:

```hcl
provider "aws" {
  default_tags {
    tags = { Environment = "prod" }
  }
}
```

### Resource Already Exists

**Error:**
```
Error: creating S3 Bucket (my-bucket): BucketAlreadyOwnedByYou
```

**Fix:** Import the existing resource:

```bash
terraform import aws_s3_bucket.this my-bucket
```

### Timeout Errors

**Error:**
```
Error: waiting for RDS DB Instance (mydb) to be created:
timeout while waiting for state to become 'available'
```

**Fix:** Increase the timeout in the resource:

```hcl
resource "aws_db_instance" "this" {
  # ... config ...

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}
```

### API Rate Limiting

**Error:**
```
Error: error reading S3 Bucket: Throttling: Rate exceeded
```

**Fix:** Reduce parallelism:

```bash
terraform apply -parallelism=5  # Default is 10
```

For persistent issues, add retries in the provider (provider-specific):

```hcl
provider "aws" {
  region = "us-east-1"
  retry_mode  = "adaptive"
  max_retries = 10
}
```

---

## Variable and Type Errors

### Type Constraint Mismatches

**Error:**
```
Error: Invalid value for variable

var.scaling.min_size is number, required: string
```

**Fix:** Ensure the value matches the declared type. Check `terraform.tfvars` and `-var` flags for type mismatches.

```hcl
# terraform.tfvars — numbers don't use quotes
scaling = {
  min_size = 2    # Correct — number
  max_size = 10
}
```

### Optional Attribute Defaults

**Gotcha:** `optional()` with defaults only works inside `object()` types (Terraform 1.3+):

```hcl
# GOOD
variable "config" {
  type = object({
    name    = string
    timeout = optional(number, 30)
  })
}

# BAD — optional() at top level doesn't work
variable "timeout" {
  type    = optional(number, 30)  # Error!
  default = 30  # Use default instead
}
```

### Sensitive Value Exposure

**Error:**
```
Error: Output refers to sensitive values

Output "connection_string" includes a sensitive value. Use nonsensitive()
to force Terraform to treat it as non-sensitive, or mark the output as
sensitive.
```

**Fix:**

```hcl
# Option 1: Mark the output as sensitive
output "connection_string" {
  value     = "postgresql://${aws_db_instance.main.endpoint}/mydb"
  sensitive = true
}

# Option 2: Use nonsensitive() if you truly want it exposed
output "endpoint" {
  value = nonsensitive(aws_db_instance.main.endpoint)
}
```

---

## Debugging with TF_LOG

### Log Levels

```bash
# Available levels (most to least verbose):
export TF_LOG=TRACE   # Everything — very verbose
export TF_LOG=DEBUG   # Detailed debugging info
export TF_LOG=INFO    # General operational info
export TF_LOG=WARN    # Warnings only
export TF_LOG=ERROR   # Errors only

# Run terraform with logging
TF_LOG=DEBUG terraform plan
```

### Provider-Specific Logging

```bash
# Log only provider interactions (most useful for debugging)
export TF_LOG_PROVIDER=TRACE

# Log only Terraform core
export TF_LOG_CORE=TRACE

# Combine: quiet core, verbose provider
export TF_LOG_CORE=WARN
export TF_LOG_PROVIDER=DEBUG
```

### Log File Output

```bash
# Send logs to a file instead of stderr
export TF_LOG=DEBUG
export TF_LOG_PATH="/tmp/terraform-debug.log"

terraform plan

# View logs
less /tmp/terraform-debug.log

# Search for specific errors
grep -i "error\|fail\|denied" /tmp/terraform-debug.log
```

### Reading Debug Logs

Key things to look for in debug logs:

```
# API request/response details
[DEBUG] provider.aws: HTTP Request Sent: method=POST url=https://ec2.us-east-1.amazonaws.com

# Provider errors
[ERROR] provider.aws: Response contains error: err="AccessDenied: ..."

# State operations
[DEBUG] states/statemgr: writing state, lineage "abc123"

# Graph walk (dependency resolution)
[TRACE] dag/walk: visiting "aws_instance.app"
```

Useful one-liners:

```bash
# Find all errors
grep "\[ERROR\]" /tmp/terraform-debug.log

# Find API calls
grep "HTTP Request Sent" /tmp/terraform-debug.log

# Find what resources are being processed
grep "visiting" /tmp/terraform-debug.log | grep -o '"[^"]*"' | sort -u

# Find provider plugin details
grep "plugin" /tmp/terraform-debug.log | head -20
```

---

## State Surgery

### terraform state mv

Move resources within or between states. Use for refactoring without destroy/recreate.

```bash
# Rename a resource
terraform state mv aws_instance.old_name aws_instance.new_name

# Move into a module
terraform state mv aws_instance.app module.compute.aws_instance.app

# Move between modules
terraform state mv module.old.aws_vpc.main module.new.aws_vpc.main

# Move a module instance (for_each)
terraform state mv 'module.service["api"]' 'module.microservice["api"]'

# Dry run — show what would happen
terraform state mv -dry-run aws_instance.old aws_instance.new
```

### terraform state rm

Remove resources from state without destroying them. The resource continues to exist in the cloud.

```bash
# Remove a single resource
terraform state rm aws_instance.legacy

# Remove a module and all its resources
terraform state rm module.old_network

# Remove a specific instance from for_each
terraform state rm 'aws_subnet.private["us-east-1a"]'

# Remove a count instance
terraform state rm 'aws_subnet.private[0]'
```

**After `state rm`, the next `terraform plan` will show the resource as "to be created" because Terraform no longer knows about it. This is expected.**

### terraform state import

Bring existing infrastructure under Terraform management:

```bash
# Basic import
terraform import aws_s3_bucket.data my-data-bucket

# Import into a module
terraform import module.storage.aws_s3_bucket.data my-data-bucket

# Import with for_each key
terraform import 'aws_subnet.private["us-east-1a"]' subnet-abc123

# Import with count index
terraform import 'aws_instance.app[0]' i-1234567890abcdef0
```

**Finding resource IDs for import:**

```bash
# AWS — use the CLI to find resource IDs
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,Tags]' --output table
aws s3api list-buckets --query 'Buckets[*].Name'
aws rds describe-db-instances --query 'DBInstances[*].DBInstanceIdentifier'
```

### terraform state replace-provider

When providers change source addresses (e.g., community to official):

```bash
terraform state replace-provider \
  registry.terraform.io/hashicorp/aws \
  registry.terraform.io/hashicorp/aws

# More common: migrating from legacy provider paths
terraform state replace-provider \
  "registry.terraform.io/-/aws" \
  "registry.terraform.io/hashicorp/aws"
```

### Advanced State Manipulation

```bash
# List all resources in state
terraform state list

# Show details of a specific resource
terraform state show aws_instance.app

# Pull entire state to JSON (for inspection)
terraform state pull | jq '.resources[] | .type + "." + .name'

# Push a modified state (DANGEROUS — backup first!)
terraform state pull > backup.tfstate
# ... modify ...
terraform state push modified.tfstate

# Taint a resource (force recreation) — deprecated, use -replace
terraform apply -replace=aws_instance.app
```

---

## Performance Issues

### Slow Plans with Large State

```bash
# Check state size
terraform state pull | wc -c  # Bytes
terraform state list | wc -l  # Resource count

# Target specific resources to speed up plans
terraform plan -target=module.network

# Reduce refresh parallelism if hitting API limits
terraform plan -parallelism=5

# Use -refresh=false for quick syntax/logic checks (skips API calls)
terraform plan -refresh=false
```

**Long-term fix:** Split into smaller states. Each state file should manage < 200 resources.

### Reducing Provider API Calls

```bash
# Skip refresh (use cached state) when iterating on logic
terraform plan -refresh=false

# Target specific modules when you know what changed
terraform plan -target=module.compute
terraform apply -target=module.compute
```

### Parallelism Tuning

```bash
# Default parallelism is 10
terraform apply -parallelism=20  # More parallel (faster, but may hit rate limits)
terraform apply -parallelism=2   # Less parallel (slower, gentler on APIs)
```

---

## Common Error Messages Reference

| Error | Likely Cause | Quick Fix |
|-------|-------------|-----------|
| `No configuration for provider` | Missing `providers = {}` in module call | Add explicit `providers` map |
| `Cycle detected` | Circular resource references | Use separate rule/attachment resources |
| `for_each depends on resource attributes` | Computed keys in `for_each` | Use variables or data sources for keys |
| `Backend configuration changed` | Backend block was modified | `terraform init -migrate-state` |
| `State lock` | Previous run crashed | `terraform force-unlock <ID>` |
| `Provider produced inconsistent result` | Server-side defaults differ from plan | Re-run apply; set explicit values |
| `Resource already exists` | Resource created outside TF | `terraform import` |
| `Error refreshing state` | Credentials expired or resource deleted | Re-auth or `terraform state rm` |
| `Module not installed` | Missing `terraform init` | `terraform init` or `terraform init -upgrade` |
| `Unsupported Terraform Core version` | Module requires newer TF version | Upgrade Terraform or adjust constraint |
| `Inconsistent dependency lock file` | Lock file doesn't match config | `terraform init -upgrade` |
| `Output refers to sensitive values` | Output contains sensitive variable | Mark output `sensitive = true` |
| `Invalid count argument` | Count depends on unknown value | Use a variable with known value |
| `duplicate resource` | Two resources with same address | Rename one or use for_each/count |
