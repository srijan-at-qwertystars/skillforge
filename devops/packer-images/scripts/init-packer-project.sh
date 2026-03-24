#!/usr/bin/env bash
# =============================================================================
# init-packer-project.sh — Initialize a new Packer project with best practices
#
# Usage:
#   ./init-packer-project.sh <project-name> [--region <aws-region>] [--no-install]
#
# Examples:
#   ./init-packer-project.sh my-golden-image
#   ./init-packer-project.sh web-server --region eu-west-1
#   ./init-packer-project.sh base-os --no-install
#
# Creates:
#   <project-name>/
#   ├── packer.pkr.hcl          # Packer block with required plugins
#   ├── variables.pkr.hcl       # Input variables with validation
#   ├── sources.pkr.hcl         # Amazon EBS source block
#   ├── builds.pkr.hcl          # Build block with provisioners
#   ├── prod.pkrvars.hcl        # Production variable values
#   ├── dev.pkrvars.hcl         # Development variable values
#   ├── Makefile                 # Build automation targets
#   ├── .gitignore               # Ignore Packer artifacts
#   ├── scripts/
#   │   └── setup.sh            # Base provisioning script
#   ├── ansible/
#   │   ├── site.yml            # Main playbook
#   │   └── requirements.yml    # Galaxy requirements
#   └── manifests/              # Build output manifests
# =============================================================================

set -euo pipefail

# --- Defaults ---
REGION="us-east-1"
INSTALL_PLUGINS=true

# --- Parse arguments ---
if [ $# -lt 1 ]; then
  echo "Usage: $0 <project-name> [--region <aws-region>] [--no-install]"
  exit 1
fi

PROJECT_NAME="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --no-install)
      INSTALL_PLUGINS=false
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Validate ---
if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

if ! command -v packer &>/dev/null && [ "$INSTALL_PLUGINS" = true ]; then
  echo "Warning: 'packer' not found in PATH. Skipping plugin install."
  INSTALL_PLUGINS=false
fi

echo "==> Initializing Packer project: $PROJECT_NAME (region: $REGION)"

# --- Create directory structure ---
mkdir -p "$PROJECT_NAME"/{scripts,ansible,manifests}

# --- packer.pkr.hcl ---
cat > "$PROJECT_NAME/packer.pkr.hcl" <<'HCL'
packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}
HCL

# --- variables.pkr.hcl ---
cat > "$PROJECT_NAME/variables.pkr.hcl" <<HCL
variable "aws_region" {
  type        = string
  default     = "${REGION}"
  description = "AWS region for the AMI build"
  validation {
    condition     = can(regex("^[a-z]{2}-(north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9]+\$", var.aws_region))
    error_message = "Must be a valid AWS region (e.g., us-east-1)."
  }
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for the build"
}

variable "ami_prefix" {
  type        = string
  default     = "${PROJECT_NAME}"
  description = "Prefix for the AMI name"
}

variable "env" {
  type        = string
  default     = "dev"
  description = "Target environment"
  validation {
    condition     = contains(["dev", "staging", "production"], var.env)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "vpc_id" {
  type        = string
  default     = ""
  description = "VPC ID for the build instance (empty = default VPC)"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet ID for the build instance (empty = default)"
}

variable "ssh_username" {
  type        = string
  default     = "ubuntu"
  description = "SSH username for the source AMI"
}
HCL

# --- sources.pkr.hcl ---
cat > "$PROJECT_NAME/sources.pkr.hcl" <<'HCL'
locals {
  timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name  = "${var.ami_prefix}-${var.env}-${local.timestamp}"
  common_tags = {
    Name        = local.ami_name
    Environment = var.env
    ManagedBy   = "packer"
    BuildDate   = local.timestamp
  }
}

source "amazon-ebs" "main" {
  region        = var.aws_region
  instance_type = var.instance_type
  ami_name      = local.ami_name
  ssh_username  = var.ssh_username

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  vpc_id    = var.vpc_id != "" ? var.vpc_id : null
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  force_deregister      = true
  force_delete_snapshot  = true

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags          = local.common_tags
  snapshot_tags = local.common_tags
}
HCL

# --- builds.pkr.hcl ---
cat > "$PROJECT_NAME/builds.pkr.hcl" <<'HCL'
build {
  sources = ["source.amazon-ebs.main"]

  # Wait for cloud-init
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  # Base setup
  provisioner "shell" {
    script          = "scripts/setup.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
  }

  # Configuration management (uncomment to use)
  # provisioner "ansible" {
  #   playbook_file    = "ansible/site.yml"
  #   user             = var.ssh_username
  #   galaxy_file      = "ansible/requirements.yml"
  #   extra_arguments  = ["--extra-vars", "env=${var.env}"]
  #   ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  # }

  # Cleanup — MUST be last provisioner
  provisioner "shell" {
    inline = [
      "sudo rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo apt-get clean",
      "sudo sync"
    ]
  }

  post-processor "manifest" {
    output     = "manifests/manifest.json"
    strip_path = true
    custom_data = {
      ami_name   = local.ami_name
      env        = var.env
      build_date = timestamp()
    }
  }
}
HCL

# --- Variable files ---
cat > "$PROJECT_NAME/dev.pkrvars.hcl" <<HCL
aws_region    = "${REGION}"
instance_type = "t3.micro"
env           = "dev"
HCL

cat > "$PROJECT_NAME/prod.pkrvars.hcl" <<HCL
aws_region    = "${REGION}"
instance_type = "t3.medium"
env           = "production"
HCL

# --- scripts/setup.sh ---
cat > "$PROJECT_NAME/scripts/setup.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating system packages"
apt-get update -y
apt-get upgrade -y

echo "==> Installing base packages"
apt-get install -y \
  curl \
  wget \
  unzip \
  jq \
  ca-certificates \
  gnupg \
  software-properties-common

echo "==> Configuring automatic security updates"
apt-get install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

echo "==> Cleaning up"
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> Base setup complete"
BASH
chmod +x "$PROJECT_NAME/scripts/setup.sh"

# --- ansible/site.yml ---
cat > "$PROJECT_NAME/ansible/site.yml" <<'YAML'
---
- name: Configure server
  hosts: all
  become: true
  vars:
    env: "{{ lookup('env', 'ENV') | default('dev', true) }}"
  roles: []
    # Uncomment as needed:
    # - dev-sec.os-hardening
    # - dev-sec.ssh-hardening
  tasks:
    - name: Verify connectivity
      ansible.builtin.ping:
YAML

# --- ansible/requirements.yml ---
cat > "$PROJECT_NAME/ansible/requirements.yml" <<'YAML'
---
roles:
  - name: dev-sec.os-hardening
    version: "7.0.0"
  - name: dev-sec.ssh-hardening
    version: "10.0.0"

collections:
  - name: community.general
    version: ">=8.0.0"
YAML

# --- Makefile ---
cat > "$PROJECT_NAME/Makefile" <<'MAKEFILE'
.PHONY: init fmt validate build build-dev build-prod inspect clean

PACKER      ?= packer
VAR_FILE    ?= dev.pkrvars.hcl

init:
	$(PACKER) init .

fmt:
	$(PACKER) fmt -recursive .

validate: init
	$(PACKER) validate -var-file=$(VAR_FILE) .

build: validate
	$(PACKER) build -var-file=$(VAR_FILE) -color=false .

build-dev:
	$(MAKE) build VAR_FILE=dev.pkrvars.hcl

build-prod:
	$(MAKE) build VAR_FILE=prod.pkrvars.hcl

inspect:
	$(PACKER) inspect .

clean:
	rm -rf manifests/*.json
	rm -rf packer_cache/

debug: init
	PACKER_LOG=1 $(PACKER) build -var-file=$(VAR_FILE) -on-error=ask .
MAKEFILE

# --- .gitignore ---
cat > "$PROJECT_NAME/.gitignore" <<'GITIGNORE'
packer_cache/
*.auto.pkrvars.hcl
manifests/*.json
*.log
crash.log
GITIGNORE

# --- Install plugins ---
if [ "$INSTALL_PLUGINS" = true ]; then
  echo "==> Installing required plugins"
  (cd "$PROJECT_NAME" && packer init .)
fi

# --- Summary ---
echo ""
echo "✅ Packer project initialized: $PROJECT_NAME/"
echo ""
find "$PROJECT_NAME" -type f | sort | sed "s|^|   |"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  make validate          # Validate template"
echo "  make build-dev         # Build dev AMI"
echo "  make build-prod        # Build production AMI"
