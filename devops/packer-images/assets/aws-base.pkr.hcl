# =============================================================================
# aws-base.pkr.hcl — Production AWS AMI template
#
# Features:
#   - Spot pricing for cost-optimized builds
#   - Shell provisioner for base OS setup
#   - Ansible provisioner for configuration management
#   - Manifest post-processor for CI/CD integration
#   - Encrypted EBS with gp3 volumes
#   - Multi-region AMI copy support
#
# Usage:
#   packer init .
#   packer validate -var-file=prod.pkrvars.hcl .
#   packer build -var-file=prod.pkrvars.hcl .
# =============================================================================

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

# --- Variables (import from variables.pkr.hcl or override) ---

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_prefix" {
  type    = string
  default = "app-base"
}

variable "env" {
  type    = string
  default = "production"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "ami_regions" {
  type        = list(string)
  default     = []
  description = "Additional regions to copy the AMI to"
}

variable "ami_users" {
  type        = list(string)
  default     = []
  description = "AWS account IDs to share the AMI with"
}

variable "use_spot" {
  type        = bool
  default     = true
  description = "Use spot instances for cost savings during build"
}

variable "ansible_playbook" {
  type    = string
  default = "ansible/site.yml"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

# --- Locals ---

locals {
  timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name  = "${var.ami_prefix}-${var.env}-${local.timestamp}"

  common_tags = {
    Name        = local.ami_name
    Environment = var.env
    ManagedBy   = "packer"
    BuildDate   = local.timestamp
    GitSHA      = var.git_sha
  }
}

# --- Source ---

source "amazon-ebs" "main" {
  region        = var.aws_region
  instance_type = var.instance_type
  ami_name      = local.ami_name
  ssh_username  = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  # Networking
  vpc_id                              = var.vpc_id != "" ? var.vpc_id : null
  subnet_id                           = var.subnet_id != "" ? var.subnet_id : null
  associate_public_ip_address         = true
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  # Spot pricing (60-90% cost savings)
  spot_price          = var.use_spot ? "auto" : null
  spot_instance_types = var.use_spot ? ["t3.medium", "t3a.medium", "m5.large", "m5a.large"] : null

  # EBS configuration
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
  }

  # AMI distribution
  ami_regions   = var.ami_regions
  ami_users     = var.ami_users
  encrypt_boot  = true

  # Overwrite existing AMI with same name
  force_deregister     = true
  force_delete_snapshot = true

  # Timeouts
  ssh_timeout            = "10m"
  ssh_handshake_attempts = 50
  aws_polling {
    delay_seconds = 30
    max_attempts  = 60
  }

  # Tags
  tags          = local.common_tags
  snapshot_tags = local.common_tags
  run_tags      = merge(local.common_tags, { Purpose = "packer-build" })
}

# --- Build ---

build {
  sources = ["source.amazon-ebs.main"]

  # Step 1: Wait for cloud-init
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  # Step 2: Base OS setup
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "echo '==> Updating system packages'",
      "apt-get update -y",
      "apt-get upgrade -y",

      "echo '==> Installing base packages'",
      "apt-get install -y curl wget unzip jq ca-certificates gnupg lsb-release",
      "apt-get install -y software-properties-common apt-transport-https",
      "apt-get install -y unattended-upgrades",

      "echo '==> Configuring automatic security updates'",
      "dpkg-reconfigure -plow unattended-upgrades",

      "echo '==> Installing monitoring agent'",
      "wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb",
      "dpkg -i amazon-cloudwatch-agent.deb",
      "rm -f amazon-cloudwatch-agent.deb",

      "echo '==> Cleaning package cache'",
      "apt-get autoremove -y",
      "apt-get clean"
    ]
  }

  # Step 3: Configuration management with Ansible
  provisioner "ansible" {
    playbook_file = var.ansible_playbook
    user          = "ubuntu"
    galaxy_file   = "ansible/requirements.yml"

    extra_arguments = [
      "--extra-vars", "env=${var.env}",
      "--scp-extra-args", "'-O'",
      "-v"
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_FORCE_COLOR=True"
    ]
  }

  # Step 4: Security scan
  provisioner "shell" {
    inline = [
      "echo '==> Running security scan'",
      "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin",
      "sudo trivy rootfs --severity CRITICAL --exit-code 1 --quiet /",
      "sudo rm -f /usr/local/bin/trivy"
    ]
  }

  # Step 5: Cleanup (MUST be last provisioner)
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    inline = [
      "echo '==> Final cleanup'",

      "rm -f /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys",
      "rm -f /etc/ssh/ssh_host_*",
      "find /home /root -name '.bash_history' -delete 2>/dev/null || true",
      "cloud-init clean --logs --seed",
      "rm -rf /tmp/* /var/tmp/*",
      "rm -rf /var/cache/apt/archives/*.deb",
      "apt-get clean",
      "rm -rf /var/lib/apt/lists/*",

      "echo '==> Cleanup complete'",
      "sync"
    ]
  }

  # Error cleanup
  error-cleanup-provisioner "shell" {
    inline = [
      "echo 'Build failed — collecting diagnostics'",
      "sudo journalctl --no-pager -n 100 > /tmp/failure-journal.txt 2>/dev/null || true"
    ]
  }

  # Post-processing: manifest
  post-processor "manifest" {
    output     = "manifests/manifest.json"
    strip_path = true
    custom_data = {
      ami_name   = local.ami_name
      env        = var.env
      git_sha    = var.git_sha
      build_date = timestamp()
    }
  }
}
