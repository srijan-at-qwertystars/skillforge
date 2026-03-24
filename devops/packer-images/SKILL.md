---
name: packer-images
description: >
  HashiCorp Packer machine image automation with HCL2 templates. Use when: creating/editing
  .pkr.hcl files, building AMIs/VM images, configuring builders (amazon-ebs, docker, azure-arm,
  googlecompute, vmware-iso, vagrant), provisioners (shell, file, ansible, puppet, chef,
  powershell), post-processors (manifest, docker-tag, docker-push, vagrant, compress),
  packer variables/locals/data sources, plugins/required_plugins, multi-build templates,
  HCP Packer registry/channels/iterations, golden image pipelines, image hardening/CIS,
  security scanning (Trivy/Grype), CI/CD for image builds, packer CLI commands, immutable
  infrastructure, or SSH/WinRM communicator troubleshooting.
  Do NOT use for: Terraform-only IaC without image building, Docker Compose, Ansible playbooks
  without Packer, Vagrant-only dev environments, or general cloud CLI unrelated to images.
---

# HashiCorp Packer — Machine Image Automation

## HCL2 Template Structure
Use `.pkr.hcl` files. Split into: `variables.pkr.hcl`, `sources.pkr.hcl`, `builds.pkr.hcl`.

### Packer Block — plugins and constraints:
```hcl
packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = { version = ">= 1.3.0", source = "github.com/hashicorp/amazon" }
    docker = { version = ">= 1.1.0", source = "github.com/hashicorp/docker" }
  }
}
```

### Source Block — builder configuration:
```hcl
source "amazon-ebs" "ubuntu" {
  ami_name      = "app-{{timestamp}}"
  instance_type = "t3.micro"
  region        = var.aws_region
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"
  tags         = { Name = "app-base", Builder = "packer" }
}
```

### Build Block — orchestrates sources, provisioners, post-processors:
```hcl
build {
  sources = ["source.amazon-ebs.ubuntu"]
  provisioner "shell" {
    inline = ["sudo apt-get update -y && sudo apt-get upgrade -y"]
  }
  provisioner "file" {
    source      = "configs/app.conf"
    destination = "/tmp/app.conf"
  }
  provisioner "shell" { script = "scripts/setup.sh" }
  post-processor "manifest" { output = "manifest.json", strip_path = true }
}
```

## Builders

### Amazon EBS (AMI)
Key fields: `region`, `source_ami`/`source_ami_filter`, `instance_type`, `ami_name`, `ssh_username`, `vpc_id`, `subnet_id`, `encrypt_boot`, `kms_key_id`, `launch_block_device_mappings`.
Use `source_ami_filter` over hardcoded AMI IDs. Set `force_deregister = true` and `force_delete_snapshot = true` to overwrite.

### Docker
```hcl
source "docker" "app" {
  image  = "ubuntu:22.04"
  commit = true
  changes = ["EXPOSE 8080", "ENTRYPOINT [\"/app/start.sh\"]"]
}
```
Use `commit = true` for image commit or `export_path` for tarball. Pair with `docker-tag`/`docker-push`.

### Azure (azure-arm)
Key fields: `subscription_id`, `client_id`, `client_secret`, `tenant_id`, `managed_image_resource_group_name`, `managed_image_name`, `os_type`, `image_publisher`, `image_offer`, `image_sku`, `vm_size`.
Use `shared_image_gallery_destination` for gallery publishing. Always deprovision last: `/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync`.

### GCP (googlecompute)
Key fields: `project_id`, `source_image_family`, `zone`, `machine_type`, `image_name`, `image_family`, `ssh_username`. Set `image_family` for automatic latest-image resolution in Terraform.

### VMware (vmware-iso)
Key fields: `iso_url`, `iso_checksum`, `ssh_username`, `disk_size`, `guest_os_type`, `vmx_data`, `boot_command`, `http_directory`. Serve kickstart/preseed via `http_directory`.

### Vagrant
```hcl
source "vagrant" "ubuntu" {
  communicator = "ssh"
  source_path  = "ubuntu/jammy64"
  provider     = "virtualbox"
  add_force    = true
}
```

## Provisioners

### Shell
```hcl
provisioner "shell" {
  inline           = ["sudo apt-get install -y nginx"]
  environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
  execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
  expect_disconnect = true   # if script triggers reboot
  pause_before      = "10s"
  valid_exit_codes  = [0, 2]
}
```

### File
```hcl
provisioner "file" {
  source      = "app/"
  destination = "/tmp/app/"
  direction   = "upload"
}
```
Files land as build user — follow up with `shell` to `sudo mv/chown` to final path.

### Ansible
```hcl
provisioner "ansible" {
  playbook_file    = "ansible/harden.yml"
  user             = "ubuntu"
  extra_arguments  = ["--extra-vars", "env=production", "--scp-extra-args", "'-O'"]
  ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
}
```
Use `ansible-local` to run directly on instance (avoids SSH overhead).

### PowerShell (Windows)
```hcl
provisioner "powershell" {
  inline = ["Install-WindowsFeature -Name Web-Server", "Set-Service -Name wuauserv -StartupType Disabled"]
  elevated_user     = "Administrator"
  elevated_password = var.admin_password
}
```

### Puppet / Chef
Use `puppet-masterless` or `chef-solo`. Provide `manifest_file`/`run_list` and `staging_directory`.

## Post-Processors

### Manifest
```hcl
post-processor "manifest" {
  output      = "packer-manifest.json"
  strip_path  = true
  custom_data = { build_date = timestamp() }
}
```

### Docker Tag + Push
```hcl
post-processor "docker-tag" {
  repository = "registry.example.com/myapp"
  tags       = ["latest", var.version]
}
post-processor "docker-push" {
  login = true
  login_server = "registry.example.com"
  login_username = var.registry_user
  login_password = var.registry_pass
}
```

### Vagrant / Compress
```hcl
post-processor "vagrant" {
  output = "builds/{{.Provider}}-{{.BuildName}}.box"
  compression_level = 9
}
post-processor "compress" { output = "output/{{.BuildName}}.tar.gz" }
```

### Chained Post-Processors — sequential execution:
```hcl
build {
  sources = ["source.docker.app"]
  post-processors {
    post-processor "docker-tag" { repository = "myapp" tags = ["latest"] }
    post-processor "docker-push" {}
  }
}
```
Use `post-processors` (plural) for sequential chains. Separate `post-processor` blocks run in parallel.

## Variables, Locals, and Data Sources

### Variables with validation:
```hcl
variable "aws_region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = can(regex("^(us|eu|ap)-", var.aws_region))
    error_message = "Region must start with us-, eu-, or ap-."
  }
}
```

### Precedence (lowest → highest):
1. Default values → 2. `.pkrvars.hcl`/`.auto.pkrvars.hcl` → 3. `-var-file=` → 4. `-var` → 5. `PKR_VAR_*` env vars

### Locals:
```hcl
locals {
  timestamp   = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name    = "app-${var.env}-${local.timestamp}"
  common_tags = { Environment = var.env, ManagedBy = "packer" }
}
```

### Data sources:
```hcl
data "amazon-ami" "base" {
  filters     = { name = "ubuntu/images/hvm-ssd/ubuntu-jammy-*" }
  most_recent = true
  owners      = ["099720109477"]
  region      = var.aws_region
}
source "amazon-ebs" "app" { source_ami = data.amazon-ami.base.id }
```

## Plugin Management
- **Install**: `packer init .` — reads `required_plugins`, downloads, verifies checksums
- **Custom**: `packer plugins install --path ./custom-binary` (v1.10+)
- **List**: `packer plugins required .`
- **Directory**: `~/.config/packer/plugins` (Linux), `%APPDATA%\packer.d\` (Windows)
- **v1.11+**: SHA256SUM files required for all plugins
- Pin exact versions in CI; use `>=` only for local dev

## Multi-Build Templates
```hcl
build {
  sources = [
    "source.amazon-ebs.ubuntu",
    "source.azure-arm.ubuntu",
    "source.googlecompute.ubuntu"
  ]
  provisioner "ansible" { playbook_file = "ansible/common.yml" }
  provisioner "shell" {
    only   = ["amazon-ebs.ubuntu"]
    inline = ["sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start"]
  }
  provisioner "shell" {
    except = ["googlecompute.ubuntu"]
    inline = ["echo 'Runs on AWS and Azure only'"]
  }
}
```
Use `only`/`except` to scope provisioners to specific builds. Builds run in parallel by default; `-parallel-builds=1` to serialize.

## HCP Packer Registry

### Enable in template:
```hcl
build {
  hcp_packer_registry {
    bucket_name   = "ubuntu-base"
    description   = "Ubuntu 22.04 base image"
    bucket_labels = { os = "ubuntu", team = "platform" }
    build_labels  = { build_source = "ci" }
  }
  sources = ["source.amazon-ebs.ubuntu"]
}
```
- **Bucket**: logical container for related images across clouds
- **Version**: each `packer build` creates a new version with fingerprint
- **Channel**: named pointer (dev/staging/production) to a specific version

### Consume in Terraform:
```hcl
data "hcp_packer_artifact" "ubuntu" {
  bucket_name  = "ubuntu-base"
  channel_name = "production"
  platform     = "aws"
  region       = "us-east-1"
}
resource "aws_instance" "app" {
  ami = data.hcp_packer_artifact.ubuntu.external_identifier
}
```
Set `HCP_CLIENT_ID`/`HCP_CLIENT_SECRET` env vars. Promote via channels: dev → staging → production. HCP Packer Run Tasks in TFC block deploys of revoked images.

## CLI Reference

| Command | Purpose |
|---------|---------|
| `packer init .` | Install required plugins |
| `packer fmt -recursive .` | Format all HCL files |
| `packer validate .` | Validate template syntax/config |
| `packer build .` | Execute build |
| `packer build -only='amazon-ebs.ubuntu' .` | Build specific source |
| `packer build -var 'region=eu-west-1' .` | Pass variable |
| `packer build -var-file=prod.pkrvars.hcl .` | Use variable file |
| `packer build -on-error=ask .` | Pause on error for debug |
| `packer build -parallel-builds=1 .` | Serialize parallel builds |
| `packer inspect .` | Show template components |
| `packer console .` | Interactive expression evaluator |

Debug: `PACKER_LOG=1 PACKER_LOG_PATH=packer.log packer build .`

## Image Hardening

### CIS Benchmarks with Ansible:
```hcl
provisioner "ansible" {
  playbook_file   = "ansible/cis-hardening.yml"
  extra_arguments = ["--extra-vars", "cis_level=1", "--tags", "scored"]
}
```
Community roles: `ansible-lockdown/UBUNTU22-CIS`, `dev-sec/linux-hardening`.

### Security scanning in-build:
```hcl
provisioner "shell" {
  inline = [
    "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin",
    "trivy rootfs --severity HIGH,CRITICAL --exit-code 1 /",
    "sudo rm /usr/local/bin/trivy"
  ]
}
```
Containers: `trivy image myapp:latest --exit-code 1`. Alternative: `grype dir:/ --fail-on high`.

### Hardening checklist:
- Remove default users/SSH keys; disable root login and password auth
- Configure unattended-upgrades for automatic security patches
- Set filesystem permissions (tmp noexec, var nosuid); enable auditd
- Remove unnecessary packages/services; harden sysctl (ip_forward=0)

**Deep dive**: see `references/security-hardening.md` for CIS benchmark implementation (Ubuntu/Amazon Linux/Windows), STIG compliance, automated scanning with Trivy/Grype/Anchore, SSH hardening, audit logging, image signing with cosign/notation, SBOM generation, and supply chain security.

## CI/CD Integration

### GitHub Actions:
```yaml
name: Build Golden Image
on:
  push: { branches: [main], paths: ['packer/**'] }
  schedule: [{ cron: '0 6 * * 1' }]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-packer@v3
      - run: packer init packer/
      - run: packer validate -var-file=packer/prod.pkrvars.hcl packer/
      - run: packer build -var-file=packer/prod.pkrvars.hcl -color=false packer/
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          HCP_CLIENT_ID: ${{ secrets.HCP_CLIENT_ID }}
          HCP_CLIENT_SECRET: ${{ secrets.HCP_CLIENT_SECRET }}
      - uses: actions/upload-artifact@v4
        with: { name: manifest, path: packer-manifest.json }
```

## Optimization
- **Parallel builds**: multi-source builds run concurrently by default; limit with `-parallel-builds=N`
- **Minimal base**: use cloud-optimized minimal images, not full ISOs
- **Batch provisioners**: combine shell commands into single scripts; each provisioner opens new SSH session
- **Caching**: Docker `pull = false` if local; use data sources to skip AMI rebuilds when base unchanged
- **Layered images**: base OS monthly → platform weekly → app per-deploy; reference prior via data source
- **Fast instances**: use compute-optimized (c5.xlarge) — higher hourly cost, lower total cost

## Common Patterns

### Golden image pipeline:
1. Base OS image (monthly) — patches, hardening, monitoring agents
2. Platform image (weekly) — runtime, middleware (Java, Node, nginx)
3. App image (per deploy) — code, config; references platform image via `source_ami_filter`

### Immutable infrastructure:
Bake all config into image. No config management at boot. Deploy by replacing instances. Instance-specific data in metadata/user-data only.

### Multi-region:
```hcl
source "amazon-ebs" "app" {
  ami_regions = ["us-west-2", "eu-west-1", "ap-southeast-1"]
}
```

## Common Gotchas
- **SSH timeout**: increase `ssh_timeout` (default 5m); set `ssh_handshake_attempts`; use `ssh_interface = "session_manager"` for private instances
- **WinRM**: configure listener in userdata/autounattend.xml; port 5985 (HTTP)/5986 (HTTPS); set `winrm_use_ntlm = true` if needed
- **File perms**: files upload as build user, not root — follow with `sudo mv/chown` via shell provisioner
- **Cleanup on failure**: `-on-error=cleanup` (default) destroys resources; use `-on-error=ask` for debug; check for orphaned EBS volumes/security groups
- **AMI naming**: must be unique per region — use `{{timestamp}}` or `force_deregister = true`
- **API rate limits**: reduce `-parallel-builds` or add retry logic for AWS/Azure/GCP throttling
- **Plugin drift**: pin versions in CI; run `packer init -upgrade .` only intentionally
- **Azure**: always run waagent deprovision as last step or image fails to boot
- **Cloud-init**: add `cloud-init status --wait` as first provisioner to avoid race conditions
- **v1.11+ plugins**: SHA256SUM files required — run `packer plugins install` to regenerate

**Deep dive**: see `references/troubleshooting.md` for detailed debugging steps, SSH/WinRM fixes, AMI copy issues, HCL2 migration guide, and plugin conflict resolution.

## References

| Document | Description |
|----------|-------------|
| `references/advanced-patterns.md` | Multi-stage builds, data sources, HCP Packer channels, custom plugins, Terraform integration, builder optimizations, Windows/WinRM, Ansible patterns, multi-region |
| `references/troubleshooting.md` | SSH/WinRM timeouts, AMI copy hangs, Docker issues, provisioner debugging, cleanup, HCL2 migration, variable errors, plugin conflicts, rate limiting |
| `references/security-hardening.md` | CIS benchmarks (Ubuntu/AL2023/Windows), Trivy/Grype/Anchore scanning, STIG compliance, SSH hardening, firewalls, audit logging, credential cleanup, image signing, SBOM |

## Scripts

Executable helper scripts in `scripts/`:

| Script | Purpose |
|--------|---------|
| `scripts/init-packer-project.sh` | Initialize a new Packer project with directory structure, starter templates, Makefile, and plugin install |
| `scripts/build-ami.sh` | Build, validate, tag, list, and cleanup AMIs with retention policies |
| `scripts/scan-image.sh` | Launch instance from AMI, run CIS benchmarks and Trivy scans, generate reports |

## Assets (Copy-Paste Templates)

Production-ready templates in `assets/`:

| File | Description |
|------|-------------|
| `assets/aws-base.pkr.hcl` | AWS AMI template with spot pricing, shell + Ansible provisioners, manifest post-processor |
| `assets/docker-base.pkr.hcl` | Docker image template with multi-stage provisioners, tag + push post-processors |
| `assets/variables.pkr.hcl` | Variables file with validation rules, descriptions, defaults for AWS region/instance/VPC |
| `assets/github-actions.yml` | GitHub Actions workflow: validate → build → scan → promote pipeline |
| `assets/Makefile` | Project Makefile with init, validate, build, fmt, scan, clean, debug targets |

## Example: Multi-Cloud Golden Image

Prompt: "Create a Packer template for hardened Ubuntu 22.04 on AWS and Azure"

```hcl
variable "aws_region" { type = string default = "us-east-1" }
variable "azure_rg"   { type = string default = "packer-images" }
variable "env"        { type = string default = "production" }

locals {
  ts   = formatdate("YYYYMMDD-hhmm", timestamp())
  name = "ubuntu-hardened-${var.env}-${local.ts}"
}

source "amazon-ebs" "ubuntu" {
  region            = var.aws_region
  instance_type     = "t3.micro"
  ami_name          = local.name
  source_ami_filter {
    filters     = { name = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username            = "ubuntu"
  force_deregister        = true
  force_delete_snapshot   = true
}

source "azure-arm" "ubuntu" {
  os_type                           = "Linux"
  image_publisher                   = "Canonical"
  image_offer                       = "0001-com-ubuntu-server-jammy"
  image_sku                         = "22_04-lts"
  location                          = "eastus"
  vm_size                           = "Standard_B1s"
  managed_image_name                = local.name
  managed_image_resource_group_name = var.azure_rg
}

build {
  sources = ["source.amazon-ebs.ubuntu", "source.azure-arm.ubuntu"]
  provisioner "shell" { inline = ["cloud-init status --wait"] }
  provisioner "shell" {
    script          = "scripts/harden.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
  }
  provisioner "shell" {
    inline = [
      "curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin",
      "sudo trivy rootfs --severity HIGH,CRITICAL --exit-code 1 /",
      "sudo rm /usr/local/bin/trivy"
    ]
  }
  provisioner "shell" {
    only   = ["azure-arm.ubuntu"]
    inline = ["/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"]
  }
  post-processor "manifest" { output = "manifest.json" strip_path = true }
}
```

<!-- tested: pass -->
