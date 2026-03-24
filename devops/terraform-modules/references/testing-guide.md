# Terraform Module Testing Guide

## Table of Contents

- [Testing Philosophy](#testing-philosophy)
- [Terraform Test Framework (HCL-Based)](#terraform-test-framework-hcl-based)
  - [Test File Structure](#test-file-structure)
  - [Plan-Only Tests](#plan-only-tests)
  - [Apply Tests](#apply-tests)
  - [Test Variables and Overrides](#test-variables-and-overrides)
  - [Mock Providers](#mock-providers)
  - [Run Block Dependencies](#run-block-dependencies)
  - [Testing Modules](#testing-modules)
  - [Running Tests](#running-tests)
- [Terratest (Go-Based Integration Testing)](#terratest-go-based-integration-testing)
  - [Project Setup](#project-setup)
  - [Basic Test Pattern](#basic-test-pattern)
  - [Testing Outputs](#testing-outputs)
  - [HTTP and API Validation](#http-and-api-validation)
  - [Retry and Timeout Patterns](#retry-and-timeout-patterns)
  - [Parallel Tests and Test Stages](#parallel-tests-and-test-stages)
  - [Test Fixtures and Helpers](#test-fixtures-and-helpers)
  - [Cleanup and Nuke Patterns](#cleanup-and-nuke-patterns)
- [TFLint — Custom Rules and Configuration](#tflint--custom-rules-and-configuration)
  - [Installation and Setup](#installation-and-setup)
  - [Built-in Rules](#built-in-rules)
  - [AWS-Specific Rules](#aws-specific-rules)
  - [Custom Rules](#custom-rules)
  - [CI Integration](#ci-integration)
- [Security Scanning](#security-scanning)
  - [Checkov](#checkov)
  - [tfsec / Trivy](#tfsec--trivy)
  - [Custom Security Policies](#custom-security-policies)
  - [Integrating Multiple Scanners](#integrating-multiple-scanners)
- [CI/CD Integration for Module Testing](#cicd-integration-for-module-testing)
  - [GitHub Actions Pipeline](#github-actions-pipeline)
  - [GitLab CI Pipeline](#gitlab-ci-pipeline)
  - [Testing Strategy by Stage](#testing-strategy-by-stage)
  - [Cost Management in CI](#cost-management-in-ci)
  - [Test Isolation and Naming](#test-isolation-and-naming)

---

## Testing Philosophy

Terraform module testing follows the **testing pyramid**:

1. **Static analysis** (fast, no infra cost): `terraform validate`, `terraform fmt`, tflint, tfsec/Checkov
2. **Plan tests** (fast, no infra cost): `terraform test` with `command = plan`
3. **Contract tests** (fast): Validate inputs, outputs, and variable validation rules
4. **Integration tests** (slow, creates real infra): `terraform test` with `command = apply`, Terratest
5. **End-to-end tests** (slowest): Full stack deployment validation

Run levels 1-3 on every PR. Run level 4 on merge to main or nightly. Run level 5 before releases.

---

## Terraform Test Framework (HCL-Based)

Native testing was introduced in Terraform 1.6. Tests are written in HCL and live in `*.tftest.hcl` files.

### Test File Structure

```hcl
# tests/main.tftest.hcl

# Global variables for all runs in this file
variables {
  name        = "test-module"
  environment = "dev"
}

# Optional: override providers for testing
provider "aws" {
  region = "us-east-1"
  # Use a test account or localstack
  skip_credentials_validation = true
  skip_metadata_api_check     = true
}

run "validates_name_variable" {
  command = plan

  variables {
    name = ""  # Override global variable for this run
  }

  expect_failures = [var.name]
}

run "creates_resources" {
  command = plan

  assert {
    condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR block mismatch."
  }
}
```

### Plan-Only Tests

Plan tests validate configuration logic without creating real resources. They're fast and free.

```hcl
run "plan_correct_resource_count" {
  command = plan

  variables {
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "Expected 3 private subnets, got ${length(aws_subnet.private)}."
  }

  assert {
    condition     = aws_vpc.main.enable_dns_hostnames == true
    error_message = "DNS hostnames should be enabled."
  }
}

run "plan_tags_applied" {
  command = plan

  variables {
    tags = { Team = "platform", CostCenter = "12345" }
  }

  assert {
    condition     = aws_vpc.main.tags["Team"] == "platform"
    error_message = "Team tag not applied."
  }
}
```

### Apply Tests

Apply tests create real infrastructure, validate it, then destroy it. Use sparingly due to cost and time.

```hcl
run "apply_creates_vpc" {
  command = apply

  variables {
    name       = "test-vpc"
    cidr_block = "10.99.0.0/16"
  }

  assert {
    condition     = output.vpc_id != ""
    error_message = "VPC ID should not be empty after apply."
  }

  assert {
    condition     = length(output.private_subnet_ids) > 0
    error_message = "Should have at least one private subnet."
  }
}

# This run uses resources created by the previous run
run "verify_vpc_exists" {
  command = plan

  module {
    source = "./tests/verify-vpc"
  }

  variables {
    vpc_id = run.apply_creates_vpc.vpc_id
  }

  assert {
    condition     = data.aws_vpc.test.state == "available"
    error_message = "VPC should be in available state."
  }
}
```

### Test Variables and Overrides

```hcl
# Global defaults for the file
variables {
  name        = "test"
  environment = "dev"
  cidr_block  = "10.0.0.0/16"
}

# Per-run overrides
run "staging_config" {
  command = plan

  variables {
    environment = "staging"
  }

  assert {
    condition     = aws_instance.app.instance_type == "t3.medium"
    error_message = "Staging should use t3.medium."
  }
}

run "prod_config" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = aws_instance.app.instance_type == "m5.large"
    error_message = "Prod should use m5.large."
  }
}
```

### Mock Providers

Terraform 1.7+ supports mock providers for testing without real credentials:

```hcl
# tests/unit.tftest.hcl

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_resource "aws_vpc" {
    defaults = {
      id         = "vpc-mock123"
      cidr_block = "10.0.0.0/16"
    }
  }
}

run "unit_test_with_mocks" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 3
    error_message = "Expected 3 subnets."
  }
}
```

### Run Block Dependencies

Runs execute sequentially. Later runs can reference outputs from earlier runs:

```hcl
run "setup_network" {
  command = apply

  module {
    source = "./modules/network"
  }

  variables {
    cidr = "10.0.0.0/16"
  }
}

run "deploy_application" {
  command = apply

  variables {
    vpc_id     = run.setup_network.vpc_id
    subnet_ids = run.setup_network.private_subnet_ids
  }

  assert {
    condition     = output.app_url != ""
    error_message = "Application URL should be set."
  }
}
```

### Testing Modules

Test a module by specifying its source:

```hcl
run "test_child_module" {
  command = plan

  module {
    source = "./modules/security-group"
  }

  variables {
    vpc_id = "vpc-test123"
    name   = "test-sg"
    ingress_rules = [
      { port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
    ]
  }

  assert {
    condition     = length(aws_security_group.this.ingress) == 1
    error_message = "Expected 1 ingress rule."
  }
}
```

### Running Tests

```bash
# Run all tests
terraform test

# Run a specific test file
terraform test -filter=tests/main.tftest.hcl

# Verbose output
terraform test -verbose

# Run with specific variable files
terraform test -var-file=testing.tfvars

# JSON output (for CI parsing)
terraform test -json
```

---

## Terratest (Go-Based Integration Testing)

Terratest provides full-lifecycle integration testing with real infrastructure.

### Project Setup

```
modules/vpc/
├── main.tf
├── variables.tf
├── outputs.tf
├── tests/
│   ├── go.mod
│   ├── go.sum
│   └── vpc_test.go
└── examples/
    └── complete/
        ├── main.tf
        └── outputs.tf
```

Initialize Go modules:

```bash
cd modules/vpc/tests
go mod init github.com/org/terraform-modules/modules/vpc/tests
go get github.com/gruntwork-io/terratest/modules/terraform
go get github.com/stretchr/testify/assert
```

### Basic Test Pattern

```go
package test

import (
    "testing"

    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/assert"
)

func TestVpcModule(t *testing.T) {
    t.Parallel()

    terraformOptions := &terraform.Options{
        TerraformDir: "../examples/complete",
        Vars: map[string]interface{}{
            "name":        "test-vpc",
            "environment": "test",
            "cidr_block":  "10.99.0.0/16",
        },
        // Retry on known transient errors
        MaxRetries:         3,
        TimeBetweenRetries: 5 * time.Second,
        RetryableTerraformErrors: map[string]string{
            "RequestError": "Transient AWS API error",
        },
    }

    // Clean up after test
    defer terraform.Destroy(t, terraformOptions)

    // Deploy
    terraform.InitAndApply(t, terraformOptions)

    // Validate outputs
    vpcId := terraform.Output(t, terraformOptions, "vpc_id")
    assert.NotEmpty(t, vpcId)
    assert.Contains(t, vpcId, "vpc-")

    subnetIds := terraform.OutputList(t, terraformOptions, "private_subnet_ids")
    assert.Equal(t, 3, len(subnetIds))
}
```

### Testing Outputs

```go
func TestModuleOutputs(t *testing.T) {
    t.Parallel()

    opts := &terraform.Options{
        TerraformDir: "../examples/complete",
        Vars: map[string]interface{}{
            "name": "output-test",
        },
    }

    defer terraform.Destroy(t, opts)
    terraform.InitAndApply(t, opts)

    // String output
    vpcId := terraform.Output(t, opts, "vpc_id")
    assert.Regexp(t, `^vpc-[a-z0-9]+$`, vpcId)

    // List output
    subnets := terraform.OutputList(t, opts, "subnet_ids")
    assert.GreaterOrEqual(t, len(subnets), 2)

    // Map output
    tags := terraform.OutputMap(t, opts, "tags")
    assert.Equal(t, "output-test", tags["Name"])

    // Complex output (JSON)
    outputJson := terraform.OutputJson(t, opts, "config")
    // Parse and validate JSON...
}
```

### HTTP and API Validation

```go
import (
    http_helper "github.com/gruntwork-io/terratest/modules/http-helper"
    "github.com/gruntwork-io/terratest/modules/aws"
)

func TestApplicationEndpoint(t *testing.T) {
    t.Parallel()

    opts := &terraform.Options{
        TerraformDir: "../examples/complete",
    }

    defer terraform.Destroy(t, opts)
    terraform.InitAndApply(t, opts)

    // Test HTTP endpoint
    url := terraform.Output(t, opts, "app_url")
    http_helper.HttpGetWithRetry(
        t,
        url,
        nil,               // TLS config
        200,               // Expected status code
        "OK",              // Expected body substring
        30,                // Max retries
        10 * time.Second,  // Time between retries
    )

    // Test AWS resources directly
    instanceId := terraform.Output(t, opts, "instance_id")
    instance := aws.GetInstancesByTag(t, "us-east-1", "Name", "test-app")
    assert.Equal(t, 1, len(instance))
}
```

### Retry and Timeout Patterns

```go
import (
    "github.com/gruntwork-io/terratest/modules/retry"
)

func TestWithRetry(t *testing.T) {
    // Retry a check until it succeeds or times out
    retry.DoWithRetry(t, "Check service health", 30, 10*time.Second,
        func() (string, error) {
            resp, err := http.Get("http://localhost:8080/health")
            if err != nil {
                return "", err
            }
            if resp.StatusCode != 200 {
                return "", fmt.Errorf("expected 200, got %d", resp.StatusCode)
            }
            return "Service is healthy", nil
        },
    )
}
```

### Parallel Tests and Test Stages

```go
func TestFullStack(t *testing.T) {
    t.Parallel()

    opts := &terraform.Options{
        TerraformDir: "../examples/full-stack",
    }

    // Test stages allow skipping setup/teardown during development
    defer test_structure.RunTestStage(t, "teardown", func() {
        terraform.Destroy(t, opts)
    })

    test_structure.RunTestStage(t, "setup", func() {
        terraform.InitAndApply(t, opts)
    })

    test_structure.RunTestStage(t, "validate_network", func() {
        vpcId := terraform.Output(t, opts, "vpc_id")
        assert.NotEmpty(t, vpcId)
    })

    test_structure.RunTestStage(t, "validate_compute", func() {
        instanceId := terraform.Output(t, opts, "instance_id")
        assert.NotEmpty(t, instanceId)
    })
}
```

Skip stages during development:

```bash
# Skip teardown to keep infra running for debugging
SKIP_teardown=true go test -v -run TestFullStack

# Skip setup to test against existing infra
SKIP_setup=true go test -v -run TestFullStack
```

### Test Fixtures and Helpers

```go
// test_helpers.go
package test

import (
    "fmt"
    "math/rand"
    "strings"
    "time"
)

func uniqueId() string {
    rand.Seed(time.Now().UnixNano())
    return fmt.Sprintf("test-%d", rand.Intn(99999))
}

func defaultVars(overrides map[string]interface{}) map[string]interface{} {
    defaults := map[string]interface{}{
        "name":        uniqueId(),
        "environment": "test",
        "region":      "us-east-1",
    }
    for k, v := range overrides {
        defaults[k] = v
    }
    return defaults
}

func defaultOpts(t *testing.T, dir string, vars map[string]interface{}) *terraform.Options {
    return &terraform.Options{
        TerraformDir: dir,
        Vars:         defaultVars(vars),
        NoColor:      true,
    }
}
```

### Cleanup and Nuke Patterns

```go
import "github.com/gruntwork-io/cloud-nuke/aws"

// Nuclear option: clean up all test resources older than 24h
func TestCleanupStaleResources(t *testing.T) {
    regions := []string{"us-east-1", "us-west-2"}
    excludeAfter := time.Now().Add(-24 * time.Hour)

    // Only target resources with test naming pattern
    err := aws.NukeAllResources(regions, excludeAfter, aws.Config{
        ResourceFilter: func(resource aws.Resource) bool {
            return strings.HasPrefix(resource.Name, "test-")
        },
    })
    assert.NoError(t, err)
}
```

---

## TFLint — Custom Rules and Configuration

### Installation and Setup

```bash
# Install tflint
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# Initialize plugins
tflint --init

# Run
tflint --recursive
```

### Built-in Rules

```hcl
# .tflint.hcl
config {
  format = "compact"
  module = true
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Enforce naming conventions
rule "terraform_naming_convention" {
  enabled = true

  variable {
    format = "snake_case"
  }

  resource {
    format = "snake_case"
  }

  output {
    format = "snake_case"
  }
}

# Require descriptions on variables and outputs
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Enforce standard module structure
rule "terraform_standard_module_structure" {
  enabled = true
}

# Require version constraints in modules
rule "terraform_required_version" {
  enabled = true
}
```

### AWS-Specific Rules

```hcl
# .tflint.hcl
plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Flag invalid instance types
rule "aws_instance_invalid_type" {
  enabled = true
}

# Flag missing tags
rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Environment", "Team", "ManagedBy"]
}

# Prevent public S3 buckets
rule "aws_s3_bucket_invalid_acl" {
  enabled = true
}
```

### Custom Rules

Create custom rules for organization-specific standards:

```hcl
# Enforce specific variable defaults
rule "terraform_required_providers" {
  enabled = true
}

# Disallow certain resource types
rule "terraform_unused_declarations" {
  enabled = true
}
```

For truly custom rules, write a TFLint plugin in Go:

```go
// rules/no_hardcoded_regions.go
package rules

import (
    "github.com/terraform-linters/tflint-plugin-sdk/tflint"
)

type NoHardcodedRegionsRule struct {
    tflint.DefaultRule
}

func (r *NoHardcodedRegionsRule) Name() string { return "no_hardcoded_regions" }
func (r *NoHardcodedRegionsRule) Severity() tflint.Severity { return tflint.ERROR }
```

### CI Integration

```bash
#!/bin/bash
# Run tflint in CI
tflint --init
tflint --recursive --format=junit > tflint-results.xml

# With specific config
tflint --config=.tflint.hcl --recursive

# Exit code: 0 = pass, 1 = issues found, 2 = error
```

---

## Security Scanning

### Checkov

Checkov scans Terraform for security misconfigurations using built-in and custom policies.

```bash
# Install
pip install checkov

# Scan a directory
checkov -d ./modules/vpc

# Scan with specific framework
checkov -d . --framework terraform

# Output formats
checkov -d . -o json > checkov-results.json
checkov -d . -o junitxml > checkov-results.xml

# Skip specific checks
checkov -d . --skip-check CKV_AWS_18,CKV_AWS_21

# Use a baseline (only report new issues)
checkov -d . --create-baseline  # Creates .checkov.baseline
checkov -d . --baseline .checkov.baseline
```

Common Checkov checks for modules:

```
CKV_AWS_18  - Ensure S3 bucket has access logging
CKV_AWS_19  - Ensure S3 bucket has server-side encryption
CKV_AWS_21  - Ensure S3 bucket has versioning enabled
CKV_AWS_23  - Ensure every security group rule has a description
CKV_AWS_79  - Ensure Instance Metadata Service Version 1 is not enabled
CKV_AWS_145 - Ensure S3 bucket is encrypted with KMS
CKV2_AWS_6  - Ensure S3 bucket has a public access block
```

### tfsec / Trivy

tfsec (now part of Trivy) provides Terraform-specific security scanning:

```bash
# Install trivy (includes tfsec)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh

# Scan with trivy
trivy config ./modules/vpc
trivy config --severity HIGH,CRITICAL ./modules/

# Legacy tfsec (still works)
tfsec ./modules/vpc
tfsec . --format=json > tfsec-results.json

# Exclude specific rules
tfsec . --exclude=aws-s3-enable-versioning

# With custom checks directory
tfsec . --custom-check-dir=./security-policies/
```

Inline suppression for false positives:

```hcl
resource "aws_s3_bucket" "lambda_packages" {
  bucket = "lambda-packages"

  #tfsec:ignore:aws-s3-enable-versioning -- Lambda packages are immutable
}
```

### Custom Security Policies

Checkov custom policies in Python:

```python
# custom_policies/no_public_rds.py
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck
from checkov.common.models.enums import CheckResult, CheckCategories

class NoPublicRDS(BaseResourceCheck):
    def __init__(self):
        name = "Ensure RDS is not publicly accessible"
        id = "CUSTOM_AWS_1"
        supported_resources = ["aws_db_instance"]
        categories = [CheckCategories.NETWORKING]
        super().__init__(name=name, id=id, categories=categories,
                        supported_resources=supported_resources)

    def scan_resource_conf(self, conf):
        publicly_accessible = conf.get("publicly_accessible", [False])
        if publicly_accessible == [True] or publicly_accessible is True:
            return CheckResult.FAILED
        return CheckResult.PASSED

check = NoPublicRDS()
```

```bash
# Run with custom policies
checkov -d . --external-checks-dir=./custom_policies/
```

### Integrating Multiple Scanners

```bash
#!/bin/bash
# run-security-scans.sh
set -e

echo "=== TFLint ==="
tflint --init && tflint --recursive

echo "=== Checkov ==="
checkov -d . --framework terraform --compact --quiet

echo "=== Trivy ==="
trivy config --severity HIGH,CRITICAL .

echo "All security scans passed!"
```

---

## CI/CD Integration for Module Testing

### GitHub Actions Pipeline

```yaml
name: Terraform Module CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
    tags: ["v*"]

env:
  TF_VERSION: "1.9.0"
  TFLINT_VERSION: "0.52.0"

jobs:
  static-analysis:
    name: Static Analysis
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format
        run: terraform fmt -check -recursive

      - name: Terraform Init
        run: terraform init -backend=false

      - name: Terraform Validate
        run: terraform validate

      - name: TFLint
        uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: ${{ env.TFLINT_VERSION }}
      - run: tflint --init && tflint --recursive

      - name: Checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          framework: terraform
          quiet: true

  plan-tests:
    name: Plan Tests
    runs-on: ubuntu-latest
    needs: static-analysis
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Run Terraform Tests (plan only)
        run: terraform test -filter=tests/plan_*.tftest.hcl

  integration-tests:
    name: Integration Tests
    runs-on: ubuntu-latest
    needs: plan-tests
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    environment: test
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_TEST_ROLE_ARN }}
          aws-region: us-east-1

      - name: Run Terraform Tests (apply)
        run: terraform test
        timeout-minutes: 30

  release:
    name: Release
    runs-on: ubuntu-latest
    needs: [static-analysis, plan-tests]
    if: startsWith(github.ref, 'refs/tags/v')
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          generate_release_notes: true
```

### GitLab CI Pipeline

```yaml
# .gitlab-ci.yml
stages:
  - validate
  - test
  - release

variables:
  TF_VERSION: "1.9.0"

.terraform-base:
  image: hashicorp/terraform:${TF_VERSION}
  before_script:
    - terraform init -backend=false

format:
  stage: validate
  extends: .terraform-base
  script:
    - terraform fmt -check -recursive

validate:
  stage: validate
  extends: .terraform-base
  script:
    - terraform validate

tflint:
  stage: validate
  image: ghcr.io/terraform-linters/tflint:latest
  script:
    - tflint --init
    - tflint --recursive

plan-tests:
  stage: test
  extends: .terraform-base
  script:
    - terraform test

integration-tests:
  stage: test
  extends: .terraform-base
  script:
    - terraform test
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  environment: test

release:
  stage: release
  rules:
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/
  script:
    - echo "Module version ${CI_COMMIT_TAG} released"
```

### Testing Strategy by Stage

| Stage | Tools | When | Duration | Cost |
|-------|-------|------|----------|------|
| Format check | `terraform fmt` | Every commit | < 5s | Free |
| Validate | `terraform validate` | Every commit | < 10s | Free |
| Lint | tflint | Every commit | < 30s | Free |
| Security scan | Checkov, tfsec | Every PR | < 60s | Free |
| Plan tests | `terraform test` (plan) | Every PR | < 2min | Free |
| Unit tests (mocks) | `terraform test` (mock) | Every PR | < 2min | Free |
| Integration tests | `terraform test` (apply) | Merge to main | 5-30min | $$ |
| Terratest | Go test | Nightly/pre-release | 10-60min | $$$ |

### Cost Management in CI

```bash
# Use small instance types for tests
# Set max duration with -timeout
go test -v -timeout 30m ./tests/

# Clean up stale test resources
# Tag all test resources with an expiry
variable "test_tags" {
  default = {
    TestRun  = "ci-12345"
    ExpireAt = "2024-01-16T00:00:00Z"
  }
}
```

Use AWS nuke or cloud-nuke to clean stale test resources:

```bash
# Find and remove resources tagged for testing older than 24h
aws-nuke --config nuke-config.yaml --no-dry-run
```

### Test Isolation and Naming

Always use unique names in tests to enable parallel runs:

```go
func TestModule(t *testing.T) {
    t.Parallel()
    uniqueID := random.UniqueId()

    opts := &terraform.Options{
        TerraformDir: "../examples/complete",
        Vars: map[string]interface{}{
            "name": fmt.Sprintf("test-%s", uniqueID),
        },
    }
    // ...
}
```

```hcl
# In terraform test files
variables {
  name = "tftest-${uuid()}"  # Won't work — use timestamp or random
}

run "isolated_test" {
  variables {
    name = "tftest-main"
  }
  # ...
}
```
