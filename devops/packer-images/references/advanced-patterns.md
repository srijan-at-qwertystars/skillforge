# Advanced Packer Patterns

## Table of Contents

- [Multi-Stage Builds with Source Blocks](#multi-stage-builds-with-source-blocks)
- [Data Sources for Dynamic AMI Lookup](#data-sources-for-dynamic-ami-lookup)
- [HCP Packer Channels and Iterations](#hcp-packer-channels-and-iterations)
- [Custom Plugin Development](#custom-plugin-development)
- [Packer + Terraform Integration](#packer--terraform-integration)
- [Builder-Specific Optimizations](#builder-specific-optimizations)
- [Windows Image Building with WinRM](#windows-image-building-with-winrm)
- [Ansible Provisioner Patterns](#ansible-provisioner-patterns)
- [Parallel Multi-Region Builds](#parallel-multi-region-builds)
- [Dynamic Blocks and Expressions](#dynamic-blocks-and-expressions)
- [Image Ancestry Tracking](#image-ancestry-tracking)
- [Data Sources Deep Dive](#data-sources-deep-dive)
- [Custom Provisioner Scripts](#custom-provisioner-scripts)
- [CIS Benchmark Hardening in Packer](#cis-benchmark-hardening-in-packer)
- [Immutable Infrastructure Patterns](#immutable-infrastructure-patterns)

---

## Multi-Stage Builds with Source Blocks

### Layered Image Pipeline

Build images in stages where each stage references the output of the previous one. This creates a golden image hierarchy: base → platform → application.

```hcl
# Stage 1: Base OS image — run monthly
variable "base_ami_name" {
  type    = string
  default = "base-os"
}

source "amazon-ebs" "base" {
  ami_name      = "${var.base_ami_name}-{{timestamp}}"
  instance_type = "t3.medium"
  region        = "us-east-1"
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username         = "ubuntu"
  force_deregister     = true
  force_delete_snapshot = true
  tags = {
    Stage   = "base"
    OS      = "ubuntu-22.04"
    BuildTS = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.base"]

  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    inline = [
      "cloud-init status --wait",
      "apt-get update -y",
      "apt-get upgrade -y",
      "apt-get install -y curl wget unzip jq software-properties-common",
      "apt-get autoremove -y",
      "apt-get clean"
    ]
  }

  provisioner "ansible" {
    playbook_file   = "ansible/base-hardening.yml"
    extra_arguments = ["--extra-vars", "cis_level=1"]
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  }

  post-processor "manifest" {
    output     = "manifests/base-manifest.json"
    strip_path = true
    custom_data = {
      stage      = "base"
      build_date = timestamp()
    }
  }
}
```

```hcl
# Stage 2: Platform image — references base, run weekly
data "amazon-ami" "base" {
  filters = {
    name = "base-os-*"
    tag:Stage = "base"
  }
  most_recent = true
  owners      = ["self"]
  region      = "us-east-1"
}

source "amazon-ebs" "platform" {
  ami_name      = "platform-java-{{timestamp}}"
  instance_type = "t3.medium"
  region        = "us-east-1"
  source_ami    = data.amazon-ami.base.id
  ssh_username  = "ubuntu"
  tags = {
    Stage    = "platform"
    Runtime  = "java-17"
    BaseAMI  = data.amazon-ami.base.id
  }
}

build {
  sources = ["source.amazon-ebs.platform"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y openjdk-17-jre-headless",
      "sudo apt-get install -y amazon-cloudwatch-agent",
      "java -version"
    ]
  }

  post-processor "manifest" {
    output     = "manifests/platform-manifest.json"
    strip_path = true
  }
}
```

### Multi-Source Build with Conditional Provisioners

```hcl
build {
  sources = [
    "source.amazon-ebs.ubuntu",
    "source.azure-arm.ubuntu",
    "source.googlecompute.ubuntu"
  ]

  # Runs on all sources
  provisioner "shell" {
    inline = ["cloud-init status --wait"]
  }

  # Only AWS
  provisioner "shell" {
    only   = ["amazon-ebs.ubuntu"]
    inline = [
      "sudo apt-get install -y amazon-ssm-agent",
      "sudo systemctl enable amazon-ssm-agent"
    ]
  }

  # Only Azure
  provisioner "shell" {
    only   = ["azure-arm.ubuntu"]
    inline = [
      "sudo apt-get install -y walinuxagent",
      "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"
    ]
  }

  # Everything except GCP
  provisioner "shell" {
    except = ["googlecompute.ubuntu"]
    inline = ["echo 'Custom config for non-GCP platforms'"]
  }

  # Override source properties per-build
  provisioner "shell" {
    override = {
      "amazon-ebs.ubuntu" = {
        inline = ["echo 'AWS-specific final step'"]
      }
      "azure-arm.ubuntu" = {
        inline = ["echo 'Azure-specific final step'"]
      }
    }
  }
}
```

---

## Data Sources for Dynamic AMI Lookup

### Amazon AMI Data Source

```hcl
data "amazon-ami" "ubuntu_latest" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "x86_64"
  }
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  region      = var.aws_region
}

# Use in source
source "amazon-ebs" "app" {
  source_ami = data.amazon-ami.ubuntu_latest.id
  # ...
}
```

### Looking Up Your Own AMIs

```hcl
data "amazon-ami" "my_base" {
  filters = {
    name       = "base-os-*"
    "tag:Stage" = "base"
    "tag:Approved" = "true"
  }
  most_recent = true
  owners      = ["self"]
  region      = var.aws_region
}
```

### HCP Packer Data Source

```hcl
data "hcp-packer-version" "base" {
  bucket_name  = "ubuntu-base"
  channel_name = "production"
}

data "hcp-packer-artifact" "base" {
  bucket_name  = "ubuntu-base"
  version_fingerprint = data.hcp-packer-version.base.fingerprint
  platform     = "aws"
  region       = var.aws_region
}

source "amazon-ebs" "app" {
  source_ami = data.hcp-packer-artifact.base.external_identifier
  # ...
}
```

### Conditional Builds Based on Data Sources

```hcl
locals {
  base_ami_age_days = floor(
    (timestamp() - timeadd(data.amazon-ami.my_base.creation_date, "0h")) / 86400
  )
  needs_rebuild = local.base_ami_age_days > 30
}
```

---

## HCP Packer Channels and Iterations

### Channel Management Strategy

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│   dev        │────▶│  staging     │────▶│  production  │
│  (auto)      │     │  (manual)    │     │  (manual)    │
└─────────────┘     └─────────────┘     └──────────────┘
    Build            Integration          Approved
    Output           Testing              for Prod
```

### Registry Configuration

```hcl
build {
  hcp_packer_registry {
    bucket_name   = "ubuntu-base"
    description   = "Ubuntu 22.04 hardened base image"
    bucket_labels = {
      os       = "ubuntu"
      os_ver   = "22.04"
      team     = "platform"
      tier     = "base"
    }
    build_labels = {
      build_source  = "github-actions"
      git_sha       = var.git_sha
      cis_level     = "1"
    }
  }
  sources = ["source.amazon-ebs.ubuntu"]
}
```

### Channel Promotion via CLI

```bash
# List versions in a bucket
hcp packer versions list --bucket-name ubuntu-base

# Promote to staging
hcp packer channels set-version \
  --bucket-name ubuntu-base \
  --channel staging \
  --version <fingerprint>

# Promote to production after validation
hcp packer channels set-version \
  --bucket-name ubuntu-base \
  --channel production \
  --version <fingerprint>

# Revoke a bad version — blocks TFC deploys via Run Tasks
hcp packer versions revoke \
  --bucket-name ubuntu-base \
  --version <fingerprint>
```

### Iteration Lifecycle

```bash
# Automated promotion script
#!/usr/bin/env bash
BUCKET="ubuntu-base"
FINGERPRINT=$(jq -r '.builds[0].packer_run_uuid' manifest.json)

# Auto-assign to dev channel
hcp packer channels set-version \
  --bucket-name "$BUCKET" \
  --channel dev \
  --version "$FINGERPRINT"

# Run integration tests
if run_integration_tests "$FINGERPRINT"; then
  hcp packer channels set-version \
    --bucket-name "$BUCKET" \
    --channel staging \
    --version "$FINGERPRINT"
fi
```

---

## Custom Plugin Development

### Plugin Structure

```
packer-plugin-mycloud/
├── main.go
├── go.mod
├── builder/
│   └── mycloud/
│       ├── builder.go        # implements packer.Builder
│       ├── config.go         # HCL2-compatible config struct
│       ├── artifact.go       # implements packer.Artifact
│       └── step_create.go    # multistep steps
├── provisioner/
│   └── myutil/
│       └── provisioner.go
├── post-processor/
│   └── myformat/
│       └── post-processor.go
├── datasource/
│   └── mydata/
│       └── datasource.go
└── .goreleaser.yml
```

### Minimal Builder Implementation

```go
// builder.go
package mycloud

import (
    "context"
    "github.com/hashicorp/hcl/v2/hcldec"
    "github.com/hashicorp/packer-plugin-sdk/multistep"
    "github.com/hashicorp/packer-plugin-sdk/packer"
    "github.com/hashicorp/packer-plugin-sdk/commonsteps"
)

type Builder struct {
    config Config
    runner multistep.Runner
}

func (b *Builder) ConfigSpec() hcldec.ObjectSpec { return b.config.FlatMapstructure().HCL2Spec() }

func (b *Builder) Prepare(raws ...interface{}) ([]string, []string, error) {
    err := config.Decode(&b.config, &config.DecodeOpts{
        PluginType: "mycloud",
    }, raws...)
    return nil, nil, err
}

func (b *Builder) Run(ctx context.Context, ui packer.Ui, hook packer.Hook) (packer.Artifact, error) {
    steps := []multistep.Step{
        &StepCreateInstance{},
        &commonsteps.StepProvision{},
        &StepCreateImage{},
    }
    b.runner = commonsteps.NewRunner(steps, b.config.PackerConfig, ui)
    b.runner.Run(ctx, state)

    if rawErr, ok := state.GetOk("error"); ok {
        return nil, rawErr.(error)
    }
    return &Artifact{imageId: state.Get("image_id").(string)}, nil
}
```

### Config with HCL2 Spec Generation

```go
// config.go — use go generate for HCL2 spec
//go:generate packer-sdc mapstructure-to-hcl2 -type Config

type Config struct {
    common.PackerConfig `mapstructure:",squash"`
    comm.SSH            `mapstructure:",squash"`

    ApiEndpoint string `mapstructure:"api_endpoint" required:"true"`
    ApiKey      string `mapstructure:"api_key" required:"true"`
    ImageName   string `mapstructure:"image_name" required:"true"`
    InstanceSize string `mapstructure:"instance_size"`
}
```

### Building and Installing

```bash
# Build plugin
go build -o packer-plugin-mycloud

# Install locally
packer plugins install --path ./packer-plugin-mycloud github.com/myorg/mycloud

# Release with GoReleaser (required for packer init)
goreleaser release --clean
```

### GoReleaser Config

```yaml
# .goreleaser.yml
builds:
  - id: packer-plugin-mycloud
    mod_timestamp: '{{ .CommitTimestamp }}'
    binary: '{{ .ProjectName }}_v{{ .Version }}_{{ .Env.API_VERSION }}_{{ .Os }}_{{ .Arch }}'
    goos: [linux, darwin, windows]
    goarch: [amd64, arm64]
    flags: ['-trimpath']

archives:
  - format: zip
    name_template: '{{ .ProjectName }}_v{{ .Version }}_{{ .Env.API_VERSION }}_{{ .Os }}_{{ .Arch }}'

checksum:
  name_template: '{{ .ProjectName }}_v{{ .Version }}_SHA256SUMS'
  algorithm: sha256

signs:
  - artifacts: checksum
    cmd: gpg
    args: ["--batch", "-u", "{{ .Env.GPG_FINGERPRINT }}", "--output", "${signature}", "--detach-sign", "${artifact}"]
```

---

## Packer + Terraform Integration

### HCP Packer Data Source in Terraform

```hcl
# Terraform configuration
terraform {
  required_providers {
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.80"
    }
  }
}

provider "hcp" {}

data "hcp_packer_artifact" "ubuntu_base" {
  bucket_name  = "ubuntu-base"
  channel_name = "production"
  platform     = "aws"
  region       = var.aws_region
}

resource "aws_instance" "app" {
  ami           = data.hcp_packer_artifact.ubuntu_base.external_identifier
  instance_type = "t3.medium"

  tags = {
    SourceAMI       = data.hcp_packer_artifact.ubuntu_base.external_identifier
    PackerBucket    = "ubuntu-base"
    PackerChannel   = "production"
  }
}
```

### Run Tasks Integration

HCP Packer Run Tasks in Terraform Cloud automatically block `terraform apply` if:
- The referenced image version has been **revoked**
- The referenced image version has **expired** (if an expiry is set)
- No valid version exists in the channel

Setup:
1. In HCP Packer, create a Run Task URL
2. In TFC, add the Run Task to your workspace
3. Set enforcement level to `mandatory`

### Passing Outputs Between Packer and Terraform

```hcl
# Packer: output manifest
post-processor "manifest" {
  output     = "packer-manifest.json"
  strip_path = true
  custom_data = {
    ami_name   = local.ami_name
    build_date = timestamp()
    git_sha    = var.git_sha
  }
}
```

```bash
# In CI: extract AMI ID and pass to Terraform
AMI_ID=$(jq -r '.builds[-1].artifact_id' packer-manifest.json | cut -d: -f2)
terraform apply -var "ami_id=$AMI_ID"
```

---

## Builder-Specific Optimizations

### EBS Fast Launch

Pre-provision launch snapshots for faster cold boot:

```hcl
source "amazon-ebs" "fast" {
  ami_name      = "fast-launch-{{timestamp}}"
  instance_type = "c5.xlarge"
  region        = "us-east-1"
  source_ami_filter { /* ... */ }
  ssh_username  = "ubuntu"

  # Enable fast launch — pre-provisions snapshots
  fast_launch {
    enable_fast_launch = true
    target_resource_count = 5   # Number of pre-provisioned snapshots
    max_parallel_launches = 3
  }

  # EBS optimization
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true
  }
}
```

### Spot Instances for Cost Savings

```hcl
source "amazon-ebs" "spot" {
  ami_name      = "app-{{timestamp}}"
  instance_type = "c5.xlarge"
  region        = "us-east-1"
  source_ami_filter { /* ... */ }
  ssh_username  = "ubuntu"

  # Spot pricing — 60-90% cost reduction
  spot_price                          = "auto"
  spot_instance_types                 = ["c5.xlarge", "c5a.xlarge", "c5d.xlarge"]
  fleet_tags                          = { Name = "packer-spot-build" }
  spot_tags                           = { Name = "packer-spot-instance" }

  # Increase timeout — spot may take longer to fulfill
  aws_polling {
    delay_seconds = 30
    max_attempts  = 50
  }
}
```

### Session Manager (No Public IP)

```hcl
source "amazon-ebs" "private" {
  ami_name      = "private-build-{{timestamp}}"
  instance_type = "t3.medium"
  region        = "us-east-1"
  source_ami_filter { /* ... */ }

  # No public IP; connect via Session Manager
  ssh_interface           = "session_manager"
  communicator            = "ssh"
  ssh_username            = "ubuntu"
  iam_instance_profile    = "PackerSSMRole"
  associate_public_ip_address = false
  subnet_id               = "subnet-private-xxxxx"

  # Temporary security group with NO inbound rules
  temporary_security_group_source_cidrs = []
}
```

Required IAM policy for the instance profile:
```json
{
  "Effect": "Allow",
  "Action": [
    "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel",
    "ssmmessages:CreateDataChannel",
    "ssmmessages:OpenControlChannel",
    "ssmmessages:OpenDataChannel"
  ],
  "Resource": "*"
}
```

---

## Windows Image Building with WinRM

### Full Windows Template

```hcl
variable "admin_password" {
  type      = string
  sensitive = true
}

source "amazon-ebs" "windows" {
  ami_name      = "windows-2022-{{timestamp}}"
  instance_type = "m5.xlarge"
  region        = "us-east-1"

  source_ami_filter {
    filters = {
      name                = "Windows_Server-2022-English-Full-Base-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = "30m"
  winrm_use_ssl  = false
  winrm_port     = 5985
  winrm_insecure = true

  # UserData configures WinRM on boot
  user_data = <<-EOF
    <powershell>
    # Set admin password
    $admin = [adsi]("WinNT://./Administrator, user")
    $admin.SetPassword("${var.admin_password}")

    # Configure WinRM
    winrm quickconfig -q
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
    winrm set winrm/config '@{MaxTimeoutms="1800000"}'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/service/auth '@{Basic="true"}'

    # Open firewall
    netsh advfirewall firewall add rule name="WinRM" protocol=TCP dir=in localport=5985 action=allow

    # Disable UAC for provisioning
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0
    </powershell>
  EOF

  # Larger volume for Windows
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

build {
  sources = ["source.amazon-ebs.windows"]

  # Wait for WinRM
  provisioner "powershell" {
    inline = ["Write-Host 'WinRM connected successfully'"]
  }

  # Install software
  provisioner "powershell" {
    inline = [
      "Set-ExecutionPolicy Bypass -Scope Process -Force",
      "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072",
      "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
      "choco install -y googlechrome 7zip notepadplusplus"
    ]
  }

  # Windows updates
  provisioner "powershell" {
    inline = [
      "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force",
      "Install-Module -Name PSWindowsUpdate -Force",
      "Get-WindowsUpdate -AcceptAll -Install -AutoReboot"
    ]
    pause_before      = "30s"
    valid_exit_codes  = [0, 2300218, 3010]  # 3010 = reboot required
    expect_disconnect = true
  }

  # Reconnect after reboot
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Sysprep — MUST be last step
  provisioner "powershell" {
    inline = [
      "C:\\ProgramData\\Amazon\\EC2-Windows\\Launch\\Scripts\\InitializeInstance.ps1 -Schedule",
      "C:\\ProgramData\\Amazon\\EC2-Windows\\Launch\\Scripts\\SysprepInstance.ps1 -NoShutdown"
    ]
  }
}
```

### WinRM over HTTPS (Production)

```hcl
source "amazon-ebs" "windows_secure" {
  # ...
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = var.admin_password
  winrm_use_ssl    = true
  winrm_port       = 5986
  winrm_insecure   = true   # Self-signed cert

  user_data = <<-EOF
    <powershell>
    $cert = New-SelfSignedCertificate -DnsName "packer" -CertStoreLocation Cert:\LocalMachine\My
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    netsh advfirewall firewall add rule name="WinRM-HTTPS" protocol=TCP dir=in localport=5986 action=allow
    </powershell>
  EOF
}
```

---

## Ansible Provisioner Patterns

### Using Roles and Galaxy

```hcl
provisioner "ansible" {
  playbook_file = "ansible/site.yml"
  user          = "ubuntu"

  # Install Galaxy roles before running
  galaxy_file          = "ansible/requirements.yml"
  galaxy_force_install = true
  galaxy_command       = "ansible-galaxy"

  extra_arguments = [
    "--extra-vars", "env=${var.env} app_version=${var.app_version}",
    "--tags", "base,security",
    "--scp-extra-args", "'-O'",
    "-vv"
  ]

  ansible_env_vars = [
    "ANSIBLE_HOST_KEY_CHECKING=False",
    "ANSIBLE_SSH_ARGS='-o ForwardAgent=yes -o StrictHostKeyChecking=no'",
    "ANSIBLE_FORCE_COLOR=True",
    "ANSIBLE_ROLES_PATH=ansible/roles"
  ]
}
```

### Galaxy Requirements File

```yaml
# ansible/requirements.yml
roles:
  - name: dev-sec.os-hardening
    version: "7.0.0"
  - name: dev-sec.ssh-hardening
    version: "10.0.0"
  - name: geerlingguy.docker
    version: "6.1.0"
  - name: geerlingguy.node_exporter
    version: "5.0.0"

collections:
  - name: amazon.aws
    version: ">=6.0.0"
  - name: community.general
    version: ">=8.0.0"
```

### Ansible-Local (Avoids SSH Overhead)

```hcl
provisioner "ansible-local" {
  playbook_file       = "ansible/site.yml"
  playbook_dir        = "ansible"
  role_paths          = ["ansible/roles"]
  galaxy_file         = "ansible/requirements.yml"
  staging_directory   = "/tmp/packer-provisioner-ansible-local"
  clean_staging_directory = true

  extra_arguments = [
    "--extra-vars", "\"env=${var.env}\"",
    "--tags", "base,security"
  ]
}
```

**When to use which:**
| Feature | `ansible` (remote) | `ansible-local` |
|---|---|---|
| Runs on | Control machine | Target instance |
| SSH overhead | Yes (each task) | No |
| Ansible needed on | Your machine | Target instance |
| Galaxy roles | Pre-installed locally | Downloaded on target |
| Speed | Slower | Faster |
| Best for | Small playbooks | Complex multi-role |

### Multi-Playbook Pattern

```hcl
build {
  sources = ["source.amazon-ebs.ubuntu"]

  provisioner "ansible" {
    playbook_file = "ansible/01-base.yml"
    user          = "ubuntu"
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  }

  provisioner "ansible" {
    playbook_file = "ansible/02-hardening.yml"
    user          = "ubuntu"
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
    extra_arguments = ["--extra-vars", "cis_level=1"]
  }

  provisioner "ansible" {
    playbook_file   = "ansible/03-app.yml"
    user            = "ubuntu"
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
    extra_arguments = ["--extra-vars", "app_version=${var.app_version}"]
  }
}
```

---

## Parallel Multi-Region Builds

### AMI Copy to Multiple Regions

```hcl
source "amazon-ebs" "multi_region" {
  ami_name      = "app-{{timestamp}}"
  instance_type = "c5.xlarge"
  region        = "us-east-1"
  source_ami_filter { /* ... */ }
  ssh_username  = "ubuntu"

  # Copy AMI to additional regions after build
  ami_regions = [
    "us-west-2",
    "eu-west-1",
    "eu-central-1",
    "ap-southeast-1",
    "ap-northeast-1"
  ]

  # Encrypt in all regions
  encrypt_boot    = true
  region_kms_key_ids = {
    "us-east-1"      = "alias/packer"
    "us-west-2"      = "alias/packer"
    "eu-west-1"      = "alias/packer"
    "eu-central-1"   = "alias/packer"
    "ap-southeast-1" = "alias/packer"
    "ap-northeast-1" = "alias/packer"
  }

  # Share with other accounts
  ami_users = ["111111111111", "222222222222"]

  # Snapshot sharing (required for encrypted AMIs)
  snapshot_users = ["111111111111", "222222222222"]
}
```

### Parallel Multi-Cloud Build

```hcl
# Build simultaneously on AWS, Azure, and GCP
build {
  sources = [
    "source.amazon-ebs.ubuntu",
    "source.azure-arm.ubuntu",
    "source.googlecompute.ubuntu"
  ]

  # Common provisioning runs on all
  provisioner "ansible" {
    playbook_file = "ansible/common.yml"
    user          = "ubuntu"
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  }

  post-processor "manifest" {
    output     = "manifests/multi-cloud-manifest.json"
    strip_path = true
    custom_data = {
      build_date = timestamp()
    }
  }
}
```

### Controlling Parallelism

```bash
# All sources in parallel (default)
packer build .

# Serialize all builds
packer build -parallel-builds=1 .

# Limit to 2 concurrent builds
packer build -parallel-builds=2 .

# Build only specific source
packer build -only='amazon-ebs.ubuntu' .

# Exclude a source
packer build -except='googlecompute.ubuntu' .
```

### Dynamic Multi-Region with Locals

```hcl
variable "deploy_regions" {
  type    = list(string)
  default = ["us-east-1", "us-west-2", "eu-west-1"]
}

locals {
  # Primary region is first in list; copy to the rest
  primary_region   = var.deploy_regions[0]
  copy_regions     = slice(var.deploy_regions, 1, length(var.deploy_regions))
}

source "amazon-ebs" "app" {
  region      = local.primary_region
  ami_regions = local.copy_regions
  # ...
}
```

---

## Dynamic Blocks and Expressions

### Dynamic blocks for repeated nested structures

Use `dynamic` blocks to generate repeated nested blocks from variables or locals. This eliminates copy-paste for multi-region, multi-volume, or multi-tag configurations.

```hcl
variable "additional_volumes" {
  type = list(object({
    device_name = string
    volume_size = number
    volume_type = string
    encrypted   = bool
  }))
  default = [
    { device_name = "/dev/sdf", volume_size = 50,  volume_type = "gp3", encrypted = true },
    { device_name = "/dev/sdg", volume_size = 100, volume_type = "gp3", encrypted = true },
  ]
}

source "amazon-ebs" "multi_volume" {
  ami_name      = "app-${local.timestamp}"
  instance_type = "t3.large"
  region        = var.aws_region
  ssh_username  = "ubuntu"
  source_ami    = data.amazon-ami.ubuntu.id

  # Root volume
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Dynamic additional volumes from variable
  dynamic "launch_block_device_mappings" {
    for_each = var.additional_volumes
    content {
      device_name           = launch_block_device_mappings.value.device_name
      volume_size           = launch_block_device_mappings.value.volume_size
      volume_type           = launch_block_device_mappings.value.volume_type
      encrypted             = launch_block_device_mappings.value.encrypted
      delete_on_termination = true
    }
  }
}
```

### Conditional expressions in source blocks

```hcl
locals {
  # Conditional AMI encryption based on environment
  encrypt = var.env == "production" ? true : false

  # Conditional instance type — larger for prod
  build_instance = var.env == "production" ? "c5.xlarge" : "t3.micro"

  # Merge tags conditionally
  tags = merge(
    var.base_tags,
    var.env == "production" ? { Compliance = "SOC2", Backup = "daily" } : {},
  )
}
```

### for_each with locals for multi-source generation

```hcl
variable "regions" {
  type    = list(string)
  default = ["us-east-1", "us-west-2", "eu-west-1"]
}

# Generate one source block per region
locals {
  region_configs = { for r in var.regions : r => {
    instance_type = r == "us-east-1" ? "t3.medium" : "t3.small"
    ami_name      = "golden-${r}-${local.timestamp}"
  }}
}

# Note: Packer HCL2 doesn't support for_each on source blocks directly.
# Use separate source blocks or a single source with ami_regions for multi-region.
# for_each works on provisioner "shell" blocks with dynamic content:

build {
  sources = ["source.amazon-ebs.main"]

  dynamic "provisioner" {
    # Dynamic provisioners are NOT supported in Packer — use override blocks instead.
    # This is a known HCL2 limitation. Use shell scripts with arguments for dynamic behavior.
    labels   = ["shell"]
    for_each = [] # Placeholder — see override pattern below
    content {
      inline = ["echo ${provisioner.value}"]
    }
  }
}
```

### Template expressions and functions

```hcl
locals {
  # String interpolation with conditionals
  ami_suffix = var.env == "production" ? "prod" : var.env

  # formatdate for consistent naming
  date_stamp = formatdate("YYYY-MM-DD", timestamp())
  time_stamp = formatdate("hhmm", timestamp())

  # Regex replace for sanitizing names
  safe_name = replace(var.app_name, "/[^a-zA-Z0-9-]/", "-")

  # Lookup map values with defaults
  instance_map = {
    small  = "t3.micro"
    medium = "t3.medium"
    large  = "c5.xlarge"
  }
  instance_type = lookup(local.instance_map, var.size, "t3.medium")

  # Coalesce — first non-empty value
  region = coalesce(var.override_region, var.default_region, "us-east-1")

  # Flatten nested lists
  all_tags = flatten([var.base_tags, var.extra_tags])

  # JSON encode for passing structured data to provisioners
  config_json = jsonencode({
    env    = var.env
    region = var.aws_region
    app    = var.app_name
  })
}
```

---

## Image Ancestry Tracking

Track the full lineage of images from base OS through application layers.

### Tagging ancestry metadata

```hcl
locals {
  # Include parent image info in every build
  ancestry_tags = {
    ParentAMI     = data.amazon-ami.base.id
    ParentName    = data.amazon-ami.base.name
    BaseOS        = "ubuntu-22.04"
    ImageLayer    = var.image_layer   # "base", "platform", "application"
    ImageFamily   = var.image_family  # "golden-ubuntu"
    BuildPipeline = var.pipeline_name
    BuildNumber   = var.build_number
    GitRepo       = var.git_repo
    GitSHA        = var.git_sha
    GitBranch     = var.git_branch
  }
}

source "amazon-ebs" "app" {
  tags = merge(local.common_tags, local.ancestry_tags)
  # ...
}
```

### HCP Packer for centralized ancestry

```hcl
packer {
  required_plugins {
    amazon = { version = ">= 1.3.0", source = "github.com/hashicorp/amazon" }
  }
}

# HCP Packer stores ancestry automatically when you use data sources
# that reference HCP Packer channels:

data "hcp-packer-version" "base" {
  bucket_name  = "ubuntu-base"
  channel_name = "production"
}

data "hcp-packer-artifact" "base" {
  bucket_name         = "ubuntu-base"
  version_fingerprint = data.hcp-packer-version.base.fingerprint
  platform            = "aws"
  region              = var.aws_region
}

source "amazon-ebs" "app" {
  source_ami = data.hcp-packer-artifact.base.external_identifier
  # HCP Packer automatically records that this image was built FROM
  # the ubuntu-base:production channel, creating a dependency graph.
}
```

### Manifest-based ancestry chain

```hcl
# Save build metadata including parent info
post-processor "manifest" {
  output     = "manifests/manifest.json"
  strip_path = true
  custom_data = {
    parent_ami     = data.amazon-ami.base.id
    parent_name    = data.amazon-ami.base.name
    image_layer    = "application"
    image_family   = "myapp"
    build_date     = timestamp()
    git_sha        = var.git_sha
    packer_version = packer.version
  }
}
```

**Query ancestry** with the manifest chain:

```bash
# Find what base image was used for a specific AMI
aws ec2 describe-images --image-ids ami-xyz --query 'Images[0].Tags[?Key==`ParentAMI`].Value' --output text
# → ami-abc (the parent)

# Build a full ancestry chain
current="ami-xyz"
while [ -n "$current" ] && [ "$current" != "None" ]; do
  echo "$current"
  current=$(aws ec2 describe-images --image-ids "$current" \
    --query 'Images[0].Tags[?Key==`ParentAMI`].Value' --output text 2>/dev/null)
done
```

---

## Data Sources Deep Dive

### amazon-ami — dynamic AMI lookup

```hcl
# Look up latest Ubuntu with specific kernel version
data "amazon-ami" "ubuntu_hwe" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "x86_64"
    state               = "available"
  }
  most_recent = true
  owners      = ["099720109477"]
  region      = var.aws_region
}

# Look up YOUR OWN base image (layered builds)
data "amazon-ami" "my_base" {
  filters = {
    name = "base-ubuntu-production-*"
    "tag:ImageLayer" = "base"
    "tag:Environment" = "production"
  }
  most_recent = true
  owners      = ["self"]
  region      = var.aws_region
}
```

### HCP Packer data sources

```hcl
# Get the latest version from a channel
data "hcp-packer-version" "base" {
  bucket_name  = "ubuntu-base"
  channel_name = "production"
}

# Get the artifact (AMI ID) for a specific region
data "hcp-packer-artifact" "base_east" {
  bucket_name         = "ubuntu-base"
  version_fingerprint = data.hcp-packer-version.base.fingerprint
  platform            = "aws"
  region              = "us-east-1"
}

data "hcp-packer-artifact" "base_west" {
  bucket_name         = "ubuntu-base"
  version_fingerprint = data.hcp-packer-version.base.fingerprint
  platform            = "aws"
  region              = "us-west-2"
}

# Use in source blocks
source "amazon-ebs" "app_east" {
  region     = "us-east-1"
  source_ami = data.hcp-packer-artifact.base_east.external_identifier
}
```

### amazon-secretsmanager — fetch secrets during build

```hcl
data "amazon-secretsmanager" "db_password" {
  name = "production/db/password"
  key  = "password"
}

build {
  sources = ["source.amazon-ebs.app"]

  provisioner "shell" {
    environment_vars = [
      "DB_PASSWORD=${data.amazon-secretsmanager.db_password.value}"
    ]
    inline = ["echo 'Configuring database connection...'"]
  }
}
```

### amazon-parameterstore — fetch SSM parameters

```hcl
data "amazon-parameterstore" "vpc_id" {
  name   = "/infrastructure/vpc/id"
  region = var.aws_region
}

source "amazon-ebs" "in_vpc" {
  vpc_id = data.amazon-parameterstore.vpc_id.value
  # ...
}
```

---

## Custom Provisioner Scripts

### Script organization pattern

```
packer/
├── scripts/
│   ├── 00-wait-cloud-init.sh    # Phase 0: Wait for cloud-init
│   ├── 01-base-packages.sh      # Phase 1: Install base packages
│   ├── 02-security-hardening.sh # Phase 2: Harden the OS
│   ├── 03-monitoring.sh         # Phase 3: Install monitoring
│   ├── 04-app-specific.sh       # Phase 4: App-specific setup
│   ├── 99-cleanup.sh            # Phase 99: Final cleanup
│   └── lib/
│       └── common.sh            # Shared functions
```

### Idempotent provisioner scripts

```bash
#!/usr/bin/env bash
# scripts/02-security-hardening.sh — Idempotent OS hardening
set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || true

log_step() { echo "==> $*"; }

# Disable root login (idempotent)
log_step "Disabling root SSH login"
if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

# Configure sysctl (idempotent via file)
log_step "Applying sysctl hardening"
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
EOF
sysctl --system >/dev/null 2>&1

log_step "Security hardening complete"
```

### Using scripts with the build block

```hcl
build {
  sources = ["source.amazon-ebs.main"]

  # Upload scripts directory
  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/packer-scripts/"
  }

  # Execute scripts in order
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    scripts = [
      "scripts/00-wait-cloud-init.sh",
      "scripts/01-base-packages.sh",
      "scripts/02-security-hardening.sh",
      "scripts/03-monitoring.sh",
      "scripts/04-app-specific.sh",
    ]
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "APP_ENV=${var.env}",
    ]
  }

  # Cleanup MUST be last
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    scripts = ["scripts/99-cleanup.sh"]
  }
}
```

---

## CIS Benchmark Hardening in Packer

### Automated CIS Level 1 hardening provisioner

```hcl
build {
  sources = ["source.amazon-ebs.hardened"]

  # OS hardening via Ansible (recommended for CIS compliance)
  provisioner "ansible" {
    playbook_file = "ansible/cis-hardening.yml"
    extra_arguments = [
      "--extra-vars", "cis_level=1",
      "--extra-vars", "env=${var.env}",
    ]
    user = var.ssh_username
    ansible_env_vars = ["ANSIBLE_HOST_KEY_CHECKING=False"]
  }

  # Or inline shell for teams without Ansible
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "echo '==> CIS Level 1 Hardening'",

      "# 1.1 — Disable unused filesystems",
      "for fs in cramfs freevxfs jffs2 hfs hfsplus squashfs udf; do",
      "  echo \"install $fs /bin/true\" > /etc/modprobe.d/$fs.conf",
      "done",

      "# 1.5 — Restrict core dumps",
      "echo '* hard core 0' >> /etc/security/limits.conf",
      "echo 'fs.suid_dumpable = 0' >> /etc/sysctl.d/99-cis.conf",

      "# 3.x — Network hardening",
      "cat > /etc/sysctl.d/99-cis-network.conf << 'EOF'",
      "net.ipv4.ip_forward = 0",
      "net.ipv4.conf.all.send_redirects = 0",
      "net.ipv4.conf.default.send_redirects = 0",
      "net.ipv4.conf.all.accept_source_route = 0",
      "net.ipv4.conf.all.accept_redirects = 0",
      "net.ipv4.conf.default.accept_redirects = 0",
      "net.ipv4.conf.all.log_martians = 1",
      "net.ipv4.conf.all.rp_filter = 1",
      "net.ipv4.tcp_syncookies = 1",
      "net.ipv6.conf.all.accept_redirects = 0",
      "net.ipv6.conf.all.accept_ra = 0",
      "EOF",
      "sysctl --system > /dev/null 2>&1",

      "# 4.x — Auditing",
      "apt-get install -y auditd audispd-plugins",
      "systemctl enable auditd",

      "# 5.x — SSH hardening",
      "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?MaxAuthTries.*/MaxAuthTries 4/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?ClientAliveCountMax.*/ClientAliveCountMax 3/' /etc/ssh/sshd_config",
      "sed -i 's/^#\\?LoginGraceTime.*/LoginGraceTime 60/' /etc/ssh/sshd_config",

      "# 6.x — File permissions",
      "chmod 644 /etc/passwd",
      "chmod 640 /etc/shadow",
      "chmod 644 /etc/group",
      "chmod 640 /etc/gshadow",

      "echo '==> CIS hardening complete'"
    ]
  }

  # Verify compliance with CIS checks
  provisioner "shell" {
    inline = [
      "echo '==> Verifying CIS compliance'",
      "FAIL=0",
      "sysctl net.ipv4.ip_forward | grep -q '= 0' || { echo 'FAIL: ip_forward'; FAIL=1; }",
      "sshd -T 2>/dev/null | grep -qi 'permitrootlogin no' || { echo 'FAIL: PermitRootLogin'; FAIL=1; }",
      "sysctl kernel.randomize_va_space | grep -q '= 2' || { echo 'FAIL: ASLR'; FAIL=1; }",
      "[ $FAIL -eq 0 ] && echo 'CIS verification PASSED' || { echo 'CIS verification FAILED'; exit 1; }",
    ]
  }
}
```

---

## Immutable Infrastructure Patterns

### The golden image pipeline

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  Base OS     │────▶│  Platform    │────▶│  Application │
│  (monthly)   │     │  (weekly)    │     │  (per-deploy)│
└─────────────┘     └──────────────┘     └──────────────┘
  Ubuntu 24.04        + monitoring         + app binary
  + security          + logging            + app config
  + patching          + runtime            + healthcheck
```

### Implementing layers with data source chains

```hcl
# Layer 1: base.pkr.hcl — run monthly via cron
data "amazon-ami" "upstream_ubuntu" {
  filters = { name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" }
  most_recent = true
  owners      = ["099720109477"]
  region      = var.aws_region
}

source "amazon-ebs" "base" {
  source_ami = data.amazon-ami.upstream_ubuntu.id
  ami_name   = "base-ubuntu-${local.timestamp}"
  tags = merge(local.common_tags, { ImageLayer = "base" })
}

# Layer 2: platform.pkr.hcl — run weekly
data "amazon-ami" "our_base" {
  filters = { "tag:ImageLayer" = "base", name = "base-ubuntu-*" }
  most_recent = true
  owners      = ["self"]
  region      = var.aws_region
}

source "amazon-ebs" "platform" {
  source_ami = data.amazon-ami.our_base.id
  ami_name   = "platform-${local.timestamp}"
  tags = merge(local.common_tags, {
    ImageLayer = "platform"
    ParentAMI  = data.amazon-ami.our_base.id
  })
}

# Layer 3: app.pkr.hcl — run per deploy
data "amazon-ami" "our_platform" {
  filters = { "tag:ImageLayer" = "platform", name = "platform-*" }
  most_recent = true
  owners      = ["self"]
  region      = var.aws_region
}

source "amazon-ebs" "app" {
  source_ami = data.amazon-ami.our_platform.id
  ami_name   = "app-${var.app_name}-${var.version}-${local.timestamp}"
  tags = merge(local.common_tags, {
    ImageLayer  = "application"
    AppVersion  = var.version
    ParentAMI   = data.amazon-ami.our_platform.id
  })
}
```

### Blue-green deployments with image promotion

```
                    ┌──────────┐
    Build ────────▶ │   dev    │ ← auto-promote on build
                    └────┬─────┘
                         │ manual gate / tests pass
                    ┌────▼─────┐
                    │ staging  │ ← promote after integration tests
                    └────┬─────┘
                         │ approval + compliance scan
                    ┌────▼─────┐
                    │production│ ← promote after approval
                    └──────────┘
```

In HCP Packer this is managed via channels:

```bash
# After build succeeds, promote through channels
hcp packer channels set-version --bucket-name myapp --channel dev --version $FINGERPRINT
# After staging tests pass:
hcp packer channels set-version --bucket-name myapp --channel staging --version $FINGERPRINT
# After approval:
hcp packer channels set-version --bucket-name myapp --channel production --version $FINGERPRINT
```

In Terraform, consume the channel:

```hcl
# Terraform reads from the production channel
data "hcp_packer_artifact" "app" {
  bucket_name  = "myapp"
  channel_name = "production"
  platform     = "aws"
  region       = var.aws_region
}

resource "aws_instance" "app" {
  ami           = data.hcp_packer_artifact.app.external_identifier
  instance_type = "t3.medium"
}
```

### Anti-patterns to avoid in immutable infrastructure

1. **SSH into production instances to patch** — Rebuild the image and redeploy instead.
2. **Configuration drift** — All configuration baked into the image or injected via user-data at boot.
3. **Mutable state on the root volume** — Use separate EBS volumes or external storage (S3, EFS) for data.
4. **Skipping image testing** — Always run smoke tests as the final provisioner and integration tests post-build.
5. **No rollback plan** — Keep previous image versions; deploy by switching the AMI ID.
6. **Snowflake images** — Every image should be reproducible from source code + Packer template.
