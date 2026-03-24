---
name: packer-images
description: >
  Build and maintain HashiCorp Packer HCL2 templates for creating machine images.
  Triggers: "Packer template", "Packer build", "machine image", "AMI builder",
  "packer init", "HCL2 packer", "packer provisioner", "golden image", "image pipeline".
  Does NOT trigger for: "Docker image build", "Dockerfile", "Terraform infrastructure",
  "Vagrant VM", "cloud-init only". Covers builders (Amazon EBS, Azure, GCP, Docker,
  VMware, VirtualBox, QEMU), provisioners (shell, file, Ansible, Chef, Puppet,
  PowerShell), post-processors (manifest, compress, docker-push, vagrant),
  variables, locals, data sources, multi-build parallel patterns, CI/CD integration,
  image testing, and production anti-patterns.
---

# HashiCorp Packer — HCL2 Skill Reference

## File Organization

Use `.pkr.hcl` extension for all templates. Split configs by concern:

```
project/
├── variables.pkr.hcl      # All variable and local blocks
├── sources.pkr.hcl         # All source (builder) blocks
├── build.pkr.hcl           # Build, provisioner, post-processor blocks
├── data.pkr.hcl            # Data source blocks
├── plugins.pkr.hcl         # Packer block with required_plugins
└── *.auto.pkrvars.hcl      # Auto-loaded variable values
```

Run `packer init .` to install plugins before any build.

## Core Blocks

### packer block — declare required plugins and version constraints

```hcl
packer {
  required_version = ">= 1.9.0"
  required_plugins {
    amazon        = { version = ">= 1.3.0", source = "github.com/hashicorp/amazon" }
    azure         = { version = ">= 2.0.0", source = "github.com/hashicorp/azure" }
    googlecompute = { version = ">= 1.1.0", source = "github.com/hashicorp/googlecompute" }
    docker        = { version = ">= 1.0.0", source = "github.com/hashicorp/docker" }
    ansible       = { version = ">= 1.1.0", source = "github.com/hashicorp/ansible" }
  }
}
```

Always pin plugin versions. Run `packer init -upgrade .` to update.

### variable block — parameterize templates

```hcl
variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for AMI build"
  validation {
    condition     = can(regex("^(us|eu|ap|sa|ca|me|af)-", var.aws_region))
    error_message = "Must be a valid AWS region."
  }
}

variable "base_tags" {
  type = map(string)
  default = {
    Team      = "platform"
    ManagedBy = "packer"
  }
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}
```

Supply values via `-var`, `-var-file`, `*.auto.pkrvars.hcl`, or `PKR_VAR_*` env vars. Mark secrets with `sensitive = true`.

### locals block — computed values

```hcl
locals {
  timestamp  = formatdate("YYYYMMDD-hhmm", timestamp())
  image_name = "golden-${var.os_family}-${local.timestamp}"
  common_tags = merge(var.base_tags, {
    BuildDate = local.timestamp
    SourceAMI = "{{ .SourceAMI }}"
  })
}
```

### data source block — dynamic lookups

```hcl
data "amazon-ami" "ubuntu" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["099720109477"]
  region      = var.aws_region
}
```

Reference as `data.amazon-ami.ubuntu.id` in source blocks.

### source blocks — builders

#### Amazon EBS

```hcl
source "amazon-ebs" "ubuntu" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.ubuntu.id
  instance_type = "t3.micro"
  ssh_username  = var.ssh_username
  ami_name      = local.image_name
  ami_regions   = ["us-west-2", "eu-west-1"]
  tags          = local.common_tags
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }
}
```

#### Azure ARM

```hcl
source "azure-arm" "ubuntu" {
  subscription_id                   = var.azure_subscription_id
  managed_image_resource_group_name = var.azure_rg
  managed_image_name                = local.image_name
  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "0001-com-ubuntu-server-jammy"
  image_sku       = "22_04-lts"
  location        = "eastus"
  vm_size         = "Standard_B1s"
  ssh_username    = var.ssh_username
  azure_tags      = local.common_tags
}
```

#### GCP

```hcl
source "googlecompute" "ubuntu" {
  project_id          = var.gcp_project_id
  source_image_family = "ubuntu-2204-lts"
  zone         = "us-central1-a"
  machine_type = "e2-micro"
  ssh_username = var.ssh_username
  image_name   = local.image_name
  image_family = "golden-ubuntu"
  image_labels = local.common_tags
}
```

#### Docker

```hcl
source "docker" "ubuntu" { image = "ubuntu:22.04"; commit = true }
```

#### VMware ISO

```hcl
source "vmware-iso" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  shutdown_command = "sudo shutdown -P now"
  guest_os_type = "ubuntu-64"
  cpus = 2
  memory = 2048
  disk_size = 20480
  headless = true
  boot_command = ["<esc><wait>", "autoinstall ds=nocloud-net", "<enter>"]
}
```

#### VirtualBox ISO

```hcl
source "virtualbox-iso" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  guest_os_type = "Ubuntu_64"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  shutdown_command = "sudo shutdown -P now"
  disk_size  = 20480
  headless   = true
  vboxmanage = [["modifyvm", "{{.Name}}", "--memory", "2048"]]
}
```

#### QEMU

```hcl
source "qemu" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  output_directory = "output-qemu"
  disk_size    = "20G"
  format       = "qcow2"
  accelerator  = "kvm"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  shutdown_command = "sudo shutdown -P now"
  headless     = true
}
```

### build block — orchestrate sources, provisioners, post-processors

```hcl
build {
  name    = "golden-image"
  sources = ["source.amazon-ebs.ubuntu", "source.azure-arm.ubuntu", "source.googlecompute.ubuntu"]
  # Provisioners execute in declared order, on every source in parallel.
```

### Provisioners

#### shell — run inline commands or scripts

```hcl
  provisioner "shell" {
    inline           = ["sudo apt-get update -y", "sudo apt-get install -y curl jq unzip"]
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
  }
  provisioner "shell" {
    scripts = ["scripts/harden.sh", "scripts/monitoring.sh"]
  }
```

#### file — upload files or directories

```hcl
  provisioner "file" {
    source      = "configs/sshd_config"
    destination = "/tmp/sshd_config"
  }
```

Follow with a shell provisioner to move files requiring sudo.

#### ansible — run Ansible playbooks

```hcl
  provisioner "ansible" {
    playbook_file    = "ansible/site.yml"
    extra_arguments  = ["--extra-vars", "env=production", "--scp-extra-args", "'-O'"]
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
    user             = var.ssh_username
  }
```

#### PowerShell — Windows provisioning

```hcl
  provisioner "powershell" {
    inline = [
      "Install-WindowsFeature -Name Web-Server",
      "Set-Service -Name wuauserv -StartupType Disabled",
    ]
  }
```

#### Chef, Puppet

```hcl
  provisioner "chef-solo" {
    cookbook_paths = ["cookbooks"]
    run_list      = ["recipe[base::default]"]
  }
  provisioner "puppet-masterless" {
    manifest_file = "manifests/site.pp"
    module_paths  = ["modules"]
  }
```

#### override — per-source provisioner config

```hcl
  provisioner "shell" {
    inline = ["echo 'cloud-specific setup'"]
    override = {
      "amazon-ebs.ubuntu" = {
        inline = ["echo 'AWS-specific setup'", "sudo snap install amazon-ssm-agent"]
      }
    }
  }
```

### Post-processors

#### manifest — emit build metadata to JSON

```hcl
  post-processor "manifest" {
    output     = "build-manifest.json"
    strip_path = true
  }
```

#### compress — create tar.gz or zip of output

```hcl
  post-processor "compress" {
    output = "output/{{.BuildName}}.tar.gz"
  }
```

#### docker-tag + docker-push

```hcl
  post-processor "docker-tag" {
    repository = "myregistry.example.com/golden-ubuntu"
    tags       = ["latest", local.timestamp]
  }
  post-processor "docker-push" {}
```

#### vagrant

```hcl
  post-processor "vagrant" { output = "boxes/{{.BuildName}}-{{.Provider}}.box" }
```

#### shell-local — run local commands after build

```hcl
  post-processor "shell-local" { inline = ["echo 'Artifact: {{.ArtifactId}}'"] }
```

#### Chained post-processors — sequential pipeline

```hcl
  post-processors {
    post-processor "docker-tag" { repository = "myregistry.example.com/app"; tags = ["latest"] }
    post-processor "docker-push" {}
  }
}
```

## Multi-Build Parallel Patterns

List multiple sources in one build block — Packer runs them in parallel. Use `only`/`except` to restrict provisioners to specific sources:

```hcl
build {
  sources = ["source.amazon-ebs.ubuntu", "source.azure-arm.ubuntu", "source.googlecompute.ubuntu"]
  provisioner "shell" {
    only   = ["amazon-ebs.ubuntu"]
    inline = ["sudo /usr/sbin/amazon-linux-extras install epel"]
  }
}
```

Use `-parallel-builds=N` to limit concurrency. Use `-only` to target one builder.

## Variables — Passing Values

```bash
packer build -var 'aws_region=us-west-2' .            # CLI flag
packer build -var-file=prod.pkrvars.hcl .              # Var file
export PKR_VAR_aws_region=us-west-2 && packer build .  # Env var; *.auto.pkrvars.hcl auto-loads
```

## CLI Workflow

```bash
packer init .                        # Install plugins
packer fmt -check .                  # Check formatting (CI gate)
packer fmt .                         # Auto-format
packer validate .                    # Validate config
packer build .                       # Build all sources
packer build -only='amazon-ebs.*' .  # Build one source
packer build -on-error=ask .         # Debug: pause on error
PACKER_LOG=1 packer build -force .   # Debug logging + overwrite
```

## CI/CD Integration (GitHub Actions)

```yaml
name: Build Golden Images
on: { push: { paths: ['packer/**'] } }
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-packer@main
      - run: packer init . && packer fmt -check . && packer validate .
        working-directory: packer/
      - run: packer build -color=false -timestamp-ui .
        working-directory: packer/
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

Pipeline stages: init → fmt → validate → build → test → promote.

## Image Testing and Validation

Add smoke tests as the last provisioner; post-build, launch instance and run InSpec/Goss/Serverspec:

```hcl
  provisioner "shell" {
    inline = ["set -e", "systemctl is-active --quiet sshd", "test -f /etc/security/limits.conf", "echo 'Smoke tests passed'"]
  }
```

## Common Patterns

1. **Timestamp naming**: Include timestamp or git-sha in image names for uniqueness.
2. **Data sources over hardcoded IDs**: Use `data "amazon-ami"` to auto-resolve latest base.
3. **Layered builds**: Base image → app image. Rebuild base weekly, app image per deploy.
4. **Cleanup provisioner**: Remove caches, logs, SSH keys before finalization.
5. **`sensitive = true`**: Mark secret variables to prevent log leakage.
6. **HCP Packer Registry**: Push metadata for Terraform consumption and tracking.

## Anti-Patterns — Avoid

1. **Hardcoded credentials**: Use env vars or IAM roles, never inline secrets.
2. **No validation step**: Always `packer validate` before `packer build`.
3. **Mutable images**: Never SSH-patch running images; rebuild from template.
4. **Missing cleanup**: Leftover apt caches, SSH host keys, bash history leak into images.
5. **Single monolithic file**: Split templates into logical files.
6. **JSON templates**: Migrate to HCL2; JSON lacks expressions and modularity.
7. **Skipping `packer init`**: Causes missing plugin errors at build time.
8. **No image tagging**: Always tag and version images for manageability.

## Example: Input → Output
**User**: "Create a Packer template that builds an Ubuntu 22.04 AMI with nginx"

**Generated**:

```hcl
packer {
  required_plugins {
    amazon = { version = ">= 1.3.0", source = "github.com/hashicorp/amazon" }
  }
}

variable "aws_region" { type = string; default = "us-east-1" }

data "amazon-ami" "ubuntu" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  most_recent = true
  owners      = ["099720109477"]
  region      = var.aws_region
}

locals { ts = formatdate("YYYYMMDDhhmm", timestamp()) }

source "amazon-ebs" "nginx" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.ubuntu.id
  instance_type = "t3.micro"
  ssh_username  = "ubuntu"
  ami_name      = "nginx-ubuntu-${local.ts}"
  tags          = { Name = "nginx-ubuntu" }
}

build {
  sources = ["source.amazon-ebs.nginx"]
  provisioner "shell" {
    inline = [
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nginx",
      "sudo systemctl enable nginx",
      "sudo apt-get clean && sudo rm -rf /var/lib/apt/lists/* /tmp/*",
    ]
  }
  post-processor "manifest" { output = "manifest.json" }
}
```

```bash
packer init . && packer validate . && packer build .
# → ami-0abc123def456 written to manifest.json
```
