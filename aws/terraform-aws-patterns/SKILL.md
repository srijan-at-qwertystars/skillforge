---
name: terraform-aws-patterns
description:
  positive: "Use when user writes Terraform for AWS, asks about module design, state management (S3 backend, state locking), workspace strategies, VPC/ECS/Lambda/RDS patterns, or Terraform best practices for AWS infrastructure."
  negative: "Do NOT use for other cloud providers (GCP, Azure) Terraform configs, Pulumi, CDK, CloudFormation, or Terraform Cloud/Enterprise platform questions."
---

# Terraform AWS Patterns

## Project Structure

Organize by modules and environments. Never put all resources in one directory.

```
infrastructure/
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md
│   ├── ecs/
│   ├── lambda/
│   ├── rds/
│   └── s3-cloudfront/
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── backend.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   ├── staging/
│   └── prod/
├── versions.tf
└── providers.tf
```

- Each module: `main.tf`, `variables.tf`, `outputs.tf`, `README.md`.
- Each environment directory is a root module that composes child modules.
- Pin provider versions in `versions.tf` at the root and inside modules.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

## Module Design Patterns

### Composition

Compose small, focused modules. Pass outputs between them.

```hcl
module "vpc" {
  source = "../../modules/vpc"
  cidr   = var.vpc_cidr
  azs    = var.availability_zones
}

module "ecs" {
  source            = "../../modules/ecs"
  vpc_id            = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
}
```

### Input/Output Contracts

Define explicit types, descriptions, and validations on every variable.

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "instance_class" {
  type        = string
  default     = "db.t3.medium"
  description = "RDS instance class"
}
```

Export only what consumers need:

```hcl
output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC identifier"
}
```

### Versioning

Pin module sources with Git tags or registry versions. Never use `ref=main`.

```hcl
module "vpc" {
  source  = "git::https://github.com/org/tf-modules.git//vpc?ref=v2.1.0"
}
```

## State Management

### S3 + DynamoDB Backend

```hcl
terraform {
  backend "s3" {
    bucket         = "myorg-terraform-state"
    key            = "prod/networking/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

- Enable S3 versioning on the state bucket for rollback.
- Use one DynamoDB table for all state locks (partition key: `LockID`).
- Encrypt state at rest with SSE-S3 or SSE-KMS.
- Restrict bucket access with IAM policies — never public.

### State Isolation

Split state per environment and per service layer:

```
s3://myorg-terraform-state/prod/networking/terraform.tfstate
s3://myorg-terraform-state/prod/compute/terraform.tfstate
s3://myorg-terraform-state/dev/networking/terraform.tfstate
```

### Workspaces vs Directories

Prefer directory-based isolation for production. Use workspaces only for short-lived or identical environments. Access workspace name via `terraform.workspace`.

### Import and Moved Blocks

```hcl
import {
  to = aws_s3_bucket.logs
  id = "my-existing-bucket"
}

moved {
  from = aws_instance.web
  to   = module.compute.aws_instance.web
}
```

## Common AWS Patterns

### VPC with Public/Private Subnets

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project}-public-${var.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + length(var.azs))
  availability_zone = var.azs[count.index]
  tags = { Name = "${var.project}-private-${var.azs[count.index]}" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}
```

### ECS Fargate Service

```hcl
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
  setting { name = "containerInsights"; value = "enabled" }
}

resource "aws_ecs_service" "app" {
  name            = "${var.project}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }
}
```

### Lambda Function

```hcl
resource "aws_lambda_function" "processor" {
  function_name = "${var.project}-processor"
  runtime       = "python3.12"
  handler       = "handler.main"
  role          = aws_iam_role.lambda_exec.arn
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = 30
  memory_size   = 256
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.main.name }
  }
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

### RDS (Multi-AZ)

```hcl
resource "aws_db_instance" "main" {
  identifier             = "${var.project}-db"
  engine                 = "postgres"
  engine_version         = "16.4"
  instance_class         = var.instance_class
  allocated_storage      = 50
  max_allocated_storage  = 200
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = true
  publicly_accessible    = false
  username               = var.db_username
  password               = data.aws_secretsmanager_secret_version.db_password.secret_string
  backup_retention_period   = 7
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-db-final"
  lifecycle { prevent_destroy = true }
}
```

### S3 + CloudFront

```hcl
resource "aws_s3_bucket" "static" { bucket = "${var.project}-static-assets" }

resource "aws_s3_bucket_public_access_block" "static" {
  bucket = aws_s3_bucket.static.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.main.id
  }
  enabled             = true
  default_root_object = "index.html"
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }
  restrictions { geo_restriction { restriction_type = "none" } }
  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
```

## Variables and Locals

- Declare types explicitly. Use `object()` and `list()` for complex inputs.
- Set defaults only when a sensible value exists. Force required inputs.
- Use `locals` for computed values. Never embed environment-specific values in modules.

```hcl
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
  name_prefix = "${var.project}-${var.environment}"
}
```

## Data Sources vs Resources

Use `data` to reference existing infrastructure. Use `resource` to create/manage it.

```hcl
data "aws_vpc" "existing" { tags = { Name = "shared-vpc" } }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

## Lifecycle Rules

- `prevent_destroy = true` — databases, S3 buckets with data, stateful resources.
- `create_before_destroy = true` — compute resources behind load balancers for zero-downtime.
- `ignore_changes = [attr]` — use sparingly, only for externally managed attributes.

```hcl
lifecycle {
  prevent_destroy       = true
  create_before_destroy = true
  ignore_changes        = [tags["UpdatedAt"]]
}
```

## Tagging Strategy

Use `default_tags` in the provider for consistency:

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.team
    }
  }
}
```

Merge resource-specific tags: `tags = merge(local.common_tags, { Name = "${local.name_prefix}-web" })`

## Security

### IAM Least Privilege

Scope policies per service. Never use `"*"` for actions or resources in production.

```hcl
data "aws_iam_policy_document" "lambda_exec" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.main.arn]
  }
}
```

### Secrets Management

Never put secrets in `.tf` files or `terraform.tfvars`. Use SSM or Secrets Manager.

```hcl
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = "${var.project}/db-password"
}

data "aws_ssm_parameter" "api_key" {
  name = "/${var.project}/${var.environment}/api-key"
  with_decryption = true
}
```

Mark sensitive outputs with `sensitive = true`.

## Testing

Validation pipeline (fast to slow):

1. `terraform fmt -check` — formatting.
2. `terraform validate` — syntax and type errors.
3. **TFLint** — provider-aware linting.
4. **Checkov / tfsec** — security and compliance.
5. `terraform plan` — review planned changes.
6. **Terratest** — deploy and validate real infrastructure.

```hcl
# .tflint.hcl
plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

Checkov inline suppression: `#checkov:skip=CKV_AWS_18:Reason here`

## CI/CD Integration

PR pipeline: `fmt -check` → `validate` → `tflint` → `checkov` → `plan`. Apply only on merge to main.

```yaml
# .github/workflows/terraform.yml
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform fmt -check -recursive
      - run: terraform init -backend=false && terraform validate
      - run: tflint --init && tflint --recursive
      - run: checkov -d . --quiet
  plan:
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init && terraform plan -out=plan.tfplan
```

- Use OIDC for AWS auth — never store long-lived credentials.
- Store plan artifacts for audit.

## Common Anti-Patterns

### Hardcoded Values

```hcl
# BAD: ami = "ami-0abcdef1234567890", subnet_id = "subnet-abc123"
# GOOD: ami = data.aws_ami.amazon_linux.id, subnet_id = module.vpc.private_subnet_ids[0]
```

### Monolithic State

Split state by service boundary. Share values via `terraform_remote_state`:

```hcl
data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "myorg-terraform-state"
    key    = "prod/networking/terraform.tfstate"
    region = "us-east-1"
  }
}
# Then use: data.terraform_remote_state.networking.outputs.private_subnet_ids
```

### Missing depends_on

Use `depends_on` when Terraform cannot infer ordering (e.g., IAM policy attachments before Lambda).

```hcl
resource "aws_lambda_function" "processor" {
  # ...
  depends_on = [aws_iam_role_policy_attachment.lambda_exec]
}
```

### Other Anti-Patterns to Avoid

- Using `count` when `for_each` with a map is clearer and safer.
- Storing secrets in plain text without encryption.
- Skipping `lifecycle.prevent_destroy` on stateful resources.
- Not enabling state bucket versioning.
- Applying directly from local machines in production.
