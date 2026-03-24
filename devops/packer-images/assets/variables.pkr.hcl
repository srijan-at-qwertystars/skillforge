# =============================================================================
# variables.pkr.hcl — Reusable variables file with validation and descriptions
#
# Import into any Packer template. Override with:
#   - .auto.pkrvars.hcl files (auto-loaded)
#   - -var-file=prod.pkrvars.hcl
#   - -var 'aws_region=eu-west-1'
#   - PKR_VAR_aws_region=eu-west-1
# =============================================================================

# --- AWS Configuration ---

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for the build and primary AMI"

  validation {
    condition     = can(regex("^[a-z]{2}-(north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9]+$", var.aws_region))
    error_message = "Must be a valid AWS region (e.g., us-east-1, eu-west-1)."
  }
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for the build instance"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "Must be a valid EC2 instance type (e.g., t3.medium, c5.xlarge)."
  }
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC ID for the build instance. Empty string uses default VPC."

  validation {
    condition     = var.vpc_id == "" || can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "Must be a valid VPC ID (vpc-xxx) or empty string."
  }
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for the build instance. Empty string uses default subnet."

  validation {
    condition     = var.subnet_id == "" || can(regex("^subnet-[a-f0-9]+$", var.subnet_id))
    error_message = "Must be a valid Subnet ID (subnet-xxx) or empty string."
  }
}

variable "ami_regions" {
  type        = list(string)
  default     = []
  description = "Additional regions to copy the AMI to after build"
}

variable "ami_users" {
  type        = list(string)
  default     = []
  description = "AWS account IDs to share the AMI with"

  validation {
    condition     = alltrue([for id in var.ami_users : can(regex("^[0-9]{12}$", id))])
    error_message = "Each account ID must be exactly 12 digits."
  }
}

# --- Naming and Environment ---

variable "ami_prefix" {
  type        = string
  default     = "app"
  description = "Prefix for the AMI name (e.g., app, base, web)"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.ami_prefix))
    error_message = "AMI prefix must start with a letter and contain only letters, numbers, and hyphens."
  }
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Target environment for the image"

  validation {
    condition     = contains(["dev", "staging", "production"], var.env)
    error_message = "Environment must be one of: dev, staging, production."
  }
}

variable "team" {
  type        = string
  default     = "platform"
  description = "Team that owns this image"
}

# --- Build Configuration ---

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "SSH username for the source AMI"

  validation {
    condition     = contains(["ubuntu", "ec2-user", "centos", "admin", "fedora", "root"], var.ssh_username)
    error_message = "SSH username must be a recognized default for common AMIs."
  }
}

variable "volume_size" {
  type        = number
  default     = 20
  description = "Root volume size in GB"

  validation {
    condition     = var.volume_size >= 8 && var.volume_size <= 500
    error_message = "Volume size must be between 8 and 500 GB."
  }
}

variable "use_spot" {
  type        = bool
  default     = true
  description = "Use spot instances for cost-optimized builds"
}

# --- Versioning ---

variable "git_sha" {
  type        = string
  default     = "unknown"
  description = "Git commit SHA for traceability"
}

variable "build_number" {
  type        = string
  default     = "local"
  description = "CI build number for traceability"
}

# --- Sensitive ---

variable "hcp_bucket" {
  type        = string
  default     = ""
  description = "HCP Packer bucket name (empty to skip registry)"
}

# --- Locals (computed values) ---

locals {
  timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name  = "${var.ami_prefix}-${var.env}-${local.timestamp}"

  common_tags = {
    Name         = local.ami_name
    Environment  = var.env
    Team         = var.team
    ManagedBy    = "packer"
    BuildDate    = local.timestamp
    GitSHA       = var.git_sha
    BuildNumber  = var.build_number
  }
}
