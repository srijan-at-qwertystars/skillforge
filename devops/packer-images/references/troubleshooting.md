# Packer Troubleshooting Guide

## Table of Contents

- [SSH Timeout During Provisioning](#ssh-timeout-during-provisioning)
- [WinRM Authentication Failures](#winrm-authentication-failures)
- [AMI Copy Across Regions Hanging](#ami-copy-across-regions-hanging)
- [Docker Builder Context Issues](#docker-builder-context-issues)
- [Provisioner Script Failures](#provisioner-script-failures)
- [Cleanup on Failed Builds](#cleanup-on-failed-builds)
- [HCL2 Migration from JSON](#hcl2-migration-from-json)
- [Variable Validation Errors](#variable-validation-errors)
- [Plugin Version Conflicts](#plugin-version-conflicts)
- [Rate Limiting from Cloud Providers](#rate-limiting-from-cloud-providers)
- [Quick Diagnostics Checklist](#quick-diagnostics-checklist)
- [Debugging Techniques Deep Dive](#debugging-techniques-deep-dive)
- [Disk Space Issues](#disk-space-issues)
- [Authentication and Credential Problems](#authentication-and-credential-problems)
- [Slow Build Optimization](#slow-build-optimization)

---

## SSH Timeout During Provisioning

### Symptoms
```
==> amazon-ebs.ubuntu: Waiting for SSH to become available...
==> amazon-ebs.ubuntu: Timeout waiting for SSH.
```

### Root Causes and Fixes

**1. Instance not ready / cloud-init still running**
```hcl
source "amazon-ebs" "ubuntu" {
  # Increase SSH timeout (default is 5m)
  ssh_timeout           = "15m"
  ssh_handshake_attempts = 50

  # Wait for cloud-init before SSH
  pause_before_connecting = "30s"
}
```

**2. Security group blocking SSH (port 22)**
```hcl
source "amazon-ebs" "ubuntu" {
  # Packer creates a temp SG; ensure it allows your IP
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]  # or your CIDR

  # Or use an existing SG
  security_group_id = "sg-xxxxxxxx"
}
```

**3. Private subnet — no public IP**
```hcl
source "amazon-ebs" "ubuntu" {
  # Option A: Assign public IP
  associate_public_ip_address = true
  subnet_id = "subnet-public-xxxxx"

  # Option B: Use Session Manager (no public IP needed)
  ssh_interface        = "session_manager"
  iam_instance_profile = "PackerSSMRole"
}
```

**4. Wrong SSH username**
| AMI | Username |
|-----|----------|
| Ubuntu | `ubuntu` |
| Amazon Linux 2/2023 | `ec2-user` |
| RHEL | `ec2-user` |
| CentOS | `centos` |
| Debian | `admin` |
| SUSE | `ec2-user` |
| Fedora | `fedora` |

**5. SSH key issues**
```hcl
source "amazon-ebs" "ubuntu" {
  # Use a specific key pair
  ssh_keypair_name = "my-packer-key"
  ssh_private_key_file = "~/.ssh/packer_rsa"

  # Or let Packer generate a temporary key (default)
  temporary_key_pair_type = "ed25519"
}
```

**6. SSH agent forwarding conflicts**
```bash
# Disable SSH agent before running Packer
unset SSH_AUTH_SOCK
packer build .
```

### Debug SSH Issues

```bash
# Enable verbose logging
PACKER_LOG=1 packer build . 2>&1 | grep -i ssh

# Test SSH manually (find instance IP in logs)
ssh -v -o StrictHostKeyChecking=no -i /tmp/packer-key ubuntu@<ip>
```

---

## WinRM Authentication Failures

### Symptoms
```
==> amazon-ebs.windows: Waiting for WinRM to become available...
==> amazon-ebs.windows: WinRM connected, but authentication failed
```
or
```
==> amazon-ebs.windows: Timeout waiting for WinRM.
```

### Root Causes and Fixes

**1. UserData script not executing**
```hcl
# Ensure UserData is PowerShell wrapped
user_data = <<-EOF
  <powershell>
  # Must be wrapped in powershell tags for EC2
  winrm quickconfig -q
  winrm set winrm/config/service '@{AllowUnencrypted="true"}'
  winrm set winrm/config/service/auth '@{Basic="true"}'

  # Set the administrator password
  $admin = [adsi]("WinNT://./Administrator, user")
  $admin.SetPassword("${var.admin_password}")
  </powershell>
EOF
```

**2. Firewall blocking WinRM port**
```powershell
# In UserData — open WinRM ports
netsh advfirewall firewall add rule name="WinRM-HTTP" protocol=TCP dir=in localport=5985 action=allow
netsh advfirewall firewall add rule name="WinRM-HTTPS" protocol=TCP dir=in localport=5986 action=allow
```

**3. Password complexity requirements**
```hcl
# Windows requires complex passwords
variable "admin_password" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "Password must be at least 12 characters."
  }
}
```

**4. NTLM vs Basic auth**
```hcl
source "amazon-ebs" "windows" {
  communicator     = "winrm"
  winrm_username   = "Administrator"
  winrm_password   = var.admin_password
  winrm_use_ntlm   = true     # Try NTLM if Basic fails
  winrm_use_ssl     = false
  winrm_port        = 5985
  winrm_timeout     = "30m"
  winrm_insecure    = true
}
```

**5. WinRM service not started**
```powershell
# UserData: force WinRM start
Set-Service -Name WinRM -StartupType Automatic
Start-Service WinRM
winrm quickconfig -force
```

### Debug WinRM

```bash
# Check WinRM from Linux
curl -v http://<windows-ip>:5985/wsman

# Check WinRM service status (from another Windows machine)
Test-WSMan -ComputerName <ip>

# Enable Packer debug
PACKER_LOG=1 packer build -on-error=ask .
```

---

## AMI Copy Across Regions Hanging

### Symptoms
```
==> amazon-ebs.app: Copying/Encrypting AMI (ami-xxx) to other regions...
    amazon-ebs.app: Copying to: eu-west-1
    amazon-ebs.app: Copying to: ap-southeast-1
[hangs for hours]
```

### Root Causes and Fixes

**1. Large AMI size — increase polling timeout**
```hcl
source "amazon-ebs" "app" {
  ami_regions = ["us-west-2", "eu-west-1"]

  aws_polling {
    delay_seconds = 60      # Check every 60s instead of 2s
    max_attempts  = 120     # Wait up to 2 hours
  }
}
```

**2. KMS key not available in target region**
```hcl
source "amazon-ebs" "app" {
  encrypt_boot = true
  region_kms_key_ids = {
    "us-east-1" = "alias/packer"
    "us-west-2" = "alias/packer"   # Must exist in target region
    "eu-west-1" = "alias/packer"
  }
}
```

**3. Cross-account copy permissions**
```json
{
  "Sid": "AllowCrossAccountCopy",
  "Effect": "Allow",
  "Action": [
    "ec2:CopyImage",
    "ec2:DescribeImages",
    "ec2:ModifyImageAttribute"
  ],
  "Resource": "*"
}
```

**4. API throttling during copy**
```hcl
# Reduce parallel copies
source "amazon-ebs" "app" {
  ami_regions = ["us-west-2", "eu-west-1"]
  # Copy happens sequentially by default; throttling is usually
  # from too many concurrent packer builds, not region copies
}
```

**5. Workaround: copy in a separate step**
```bash
# Build AMI in primary region only
packer build -var 'ami_regions=[]' .

# Copy manually with AWS CLI (more control)
AMI_ID=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
for region in us-west-2 eu-west-1; do
  aws ec2 copy-image \
    --source-region us-east-1 \
    --source-image-id "$AMI_ID" \
    --name "app-copy" \
    --region "$region" &
done
wait
```

---

## Docker Builder Context Issues

### Symptoms
```
==> docker.app: Error committing container: ...
==> docker.app: Error exporting container: ...
==> docker.app: Cannot connect to the Docker daemon
```

### Root Causes and Fixes

**1. Docker daemon not running**
```bash
# Verify Docker is running
sudo systemctl status docker
sudo systemctl start docker

# In CI — use Docker-in-Docker or socket mounting
# GitHub Actions: docker is available by default on ubuntu-latest
```

**2. Permission denied**
```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Or run Packer with sudo (not recommended)
sudo packer build .
```

**3. commit vs export confusion**
```hcl
source "docker" "app" {
  image = "ubuntu:22.04"

  # Option A: commit (keeps layers, produces docker image)
  commit = true

  # Option B: export (flat tarball, loses layers)
  # export_path = "output.tar"

  # Cannot use both commit and export_path
}
```

**4. ENTRYPOINT/CMD not set on commit**
```hcl
source "docker" "app" {
  image  = "ubuntu:22.04"
  commit = true
  changes = [
    "ENTRYPOINT [\"/app/entrypoint.sh\"]",
    "CMD [\"--default-arg\"]",
    "EXPOSE 8080",
    "ENV APP_ENV=production",
    "WORKDIR /app",
    "USER appuser"
  ]
}
```

**5. Privileged mode for systemd/services**
```hcl
source "docker" "systemd" {
  image      = "ubuntu:22.04"
  commit     = true
  privileged = true
  volumes = {
    "/sys/fs/cgroup" = "/sys/fs/cgroup:rw"
  }
  run_command = [
    "-d", "-i", "-t",
    "--name", "{{.Name}}",
    "--privileged",
    "{{.Image}}",
    "/sbin/init"
  ]
}
```

**6. Build context too large**
```hcl
# Use .dockerignore equivalent: only upload needed files
provisioner "file" {
  source      = "app/config.json"       # Specific file, not entire directory
  destination = "/tmp/config.json"
}
```

---

## Provisioner Script Failures

### Symptoms
```
==> amazon-ebs.ubuntu: Provisioning with shell script: scripts/setup.sh
    amazon-ebs.ubuntu: /tmp/packer-shell123: line 42: command not found
==> amazon-ebs.ubuntu: Script exited with non-zero exit status: 127
```

### Exit Code Debugging

| Exit Code | Meaning | Common Cause |
|-----------|---------|--------------|
| 1 | General error | Command failed |
| 2 | Misuse of shell | Syntax error in script |
| 126 | Permission denied | Script not executable |
| 127 | Command not found | Missing binary / bad PATH |
| 128+N | Signal N | Killed (137 = OOM kill) |
| 255 | SSH error | Connection dropped |

### Fixes

**1. Script not executable**
```hcl
provisioner "shell" {
  script          = "scripts/setup.sh"
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
}
```

**2. Allow specific non-zero exit codes**
```hcl
provisioner "shell" {
  inline           = ["apt-get install -y maybe-missing-pkg || true"]
  valid_exit_codes = [0, 1]
}
```

**3. Environment variables not available**
```hcl
provisioner "shell" {
  script = "scripts/setup.sh"
  environment_vars = [
    "DEBIAN_FRONTEND=noninteractive",
    "APP_VERSION=${var.app_version}",
    "BUILD_NUMBER=${var.build_number}"
  ]
  # Ensure env vars are available to sudo
  execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
}
```

**4. Debug a failing script interactively**
```bash
# Pause on error to SSH in and debug
packer build -on-error=ask .

# When prompted, open another terminal:
ssh -i /tmp/packer-key ubuntu@<ip>
# Inspect /tmp/packer-shell* for the actual script
cat /tmp/packer-shell*
# Run it manually to see the error
sudo bash /tmp/packer-shell*
```

**5. Script runs before package manager is ready**
```hcl
# Wait for cloud-init and apt locks
provisioner "shell" {
  inline = [
    "cloud-init status --wait",
    "while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done",
    "sudo apt-get update -y"
  ]
}
```

**6. Reboots breaking provisioning**
```hcl
provisioner "shell" {
  inline            = ["sudo apt-get upgrade -y"]
  expect_disconnect = true
}

# Wait for SSH to come back
provisioner "shell" {
  inline       = ["echo 'Reconnected after reboot'"]
  pause_before = "30s"
}
```

---

## Cleanup on Failed Builds

### Automatic Cleanup Behavior

```bash
# Default: cleanup resources on failure
packer build .

# Keep resources for debugging
packer build -on-error=ask .     # Interactive prompt
packer build -on-error=abort .   # Stop immediately, keep resources
packer build -on-error=run-cleanup-provisioner .  # Run error-cleanup-provisioner
```

### Error Cleanup Provisioner

```hcl
build {
  sources = ["source.amazon-ebs.ubuntu"]

  provisioner "shell" {
    inline = ["./deploy-app.sh"]
  }

  # Runs ONLY when build fails
  error-cleanup-provisioner "shell" {
    inline = [
      "echo 'Build failed, cleaning up...'",
      "sudo rm -rf /tmp/build-artifacts",
      "sudo journalctl -u myapp --no-pager > /tmp/failure-logs.txt"
    ]
  }
}
```

### Manual Cleanup: AWS AMIs and Snapshots

```bash
#!/usr/bin/env bash
# Find orphaned Packer AMIs
aws ec2 describe-images \
  --owners self \
  --filters "Name=tag:Builder,Values=packer" \
  --query 'Images[?CreationDate<`2024-01-01`].[ImageId,Name,CreationDate]' \
  --output table

# Deregister an AMI
aws ec2 deregister-image --image-id ami-xxxxxxxx

# Find and delete associated snapshots
SNAPSHOTS=$(aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=description,Values=*ami-xxxxxxxx*" \
  --query 'Snapshots[].SnapshotId' \
  --output text)

for snap in $SNAPSHOTS; do
  aws ec2 delete-snapshot --snapshot-id "$snap"
done
```

### Cleanup Orphaned Resources

```bash
# Find Packer security groups (left behind on crash)
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=packer_*" \
  --query 'SecurityGroups[].[GroupId,GroupName,Description]' \
  --output table

# Delete orphaned SGs
aws ec2 delete-security-group --group-id sg-xxxxxxxx

# Find Packer key pairs
aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=packer_*" \
  --query 'KeyPairs[].KeyName' \
  --output text

# Delete orphaned key pairs
aws ec2 delete-key-pair --key-name packer_xxxxxxxx

# Find running Packer instances
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=Packer*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

---

## HCL2 Migration from JSON

### Automated Conversion

```bash
# Convert JSON template to HCL2 (Packer 1.7+)
packer hcl2_upgrade mytemplate.json

# This creates mytemplate.json.pkr.hcl
# Review and fix the output — conversion is not perfect
```

### Common Migration Issues

**1. Template functions → HCL2 functions**
```
JSON:  "{{timestamp}}"           →  HCL2: timestamp()
JSON:  "{{uuid}}"                →  HCL2: uuidv4()
JSON:  "{{env `AWS_REGION`}}"    →  HCL2: var.aws_region  (use variables instead)
JSON:  "{{user `version`}}"      →  HCL2: var.version
JSON:  "{{build `ID`}}"          →  HCL2: build.ID  (in post-processors)
JSON:  "{{isotime}}"             →  HCL2: formatdate("YYYY-MM-DD", timestamp())
```

**2. Variables**
```json
// JSON
{
  "variables": {
    "aws_region": "us-east-1",
    "version": "{{env `APP_VERSION`}}"
  }
}
```
```hcl
// HCL2
variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "version" {
  type    = string
  default = env("APP_VERSION")  // env() in default only
}
```

**3. Builders → Source blocks**
```json
// JSON
{
  "builders": [{
    "type": "amazon-ebs",
    "name": "ubuntu",
    "region": "us-east-1"
  }]
}
```
```hcl
// HCL2
source "amazon-ebs" "ubuntu" {
  region = "us-east-1"
}
build {
  sources = ["source.amazon-ebs.ubuntu"]
}
```

**4. Post-processors: sequential vs parallel**
```json
// JSON: nested array = sequential chain
{
  "post-processors": [[
    { "type": "docker-tag", "repository": "myapp" },
    { "type": "docker-push" }
  ]]
}
```
```hcl
// HCL2: use post-processors block for sequential
build {
  post-processors {
    post-processor "docker-tag" { repository = "myapp" }
    post-processor "docker-push" {}
  }
}
```

### Migration Checklist

- [ ] Run `packer hcl2_upgrade` on each JSON template
- [ ] Split into `variables.pkr.hcl`, `sources.pkr.hcl`, `builds.pkr.hcl`
- [ ] Replace `{{env}}` with proper variables + `PKR_VAR_` env vars
- [ ] Replace `{{user}}` references with `var.` references
- [ ] Convert `{{timestamp}}` and similar to function calls
- [ ] Verify `only`/`except` use `type.name` format (e.g., `amazon-ebs.ubuntu`)
- [ ] Update CI scripts from `.json` to `.` (directory-based)
- [ ] Test with `packer validate .` and `packer fmt -check .`

---

## Variable Validation Errors

### Symptoms
```
Error: Invalid value for variable

  on variables.pkr.hcl line 5:
   5: variable "aws_region" {

Region must start with us-, eu-, or ap-.
```

### Common Issues and Fixes

**1. Validation rule too strict**
```hcl
variable "aws_region" {
  type    = string
  default = "us-east-1"
  validation {
    # Wrong: misses some valid regions (me-, af-, ca-, sa-)
    condition     = can(regex("^(us|eu|ap)-", var.aws_region))
    error_message = "Invalid AWS region."
  }
}

# Fix: use a more complete regex or allowlist
variable "aws_region" {
  type    = string
  default = "us-east-1"
  validation {
    condition     = can(regex("^[a-z]{2}-(north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9]+$", var.aws_region))
    error_message = "Must be a valid AWS region (e.g., us-east-1)."
  }
}
```

**2. Type mismatch**
```bash
# Passing a number where string expected
packer build -var 'count=5' .  # count is type = number

# Fix: ensure variable types match
variable "count" {
  type    = number
  default = 1
}
```

**3. Sensitive variable not provided**
```hcl
variable "admin_password" {
  type      = string
  sensitive = true
  # No default — MUST be provided
}
```
```bash
# Fix: provide via env var, var-file, or -var flag
export PKR_VAR_admin_password="MyP@ssw0rd!"
packer build .
```

**4. Variable file not found**
```bash
# Error: var-file path wrong
packer build -var-file=production.pkrvars.hcl .

# Fix: use correct path and extension
packer build -var-file=vars/production.pkrvars.hcl .
```

**5. Auto-loaded variable files**
```
# These are auto-loaded (no -var-file needed):
*.auto.pkrvars.hcl
*.auto.pkrvars.json
```

### Variable Precedence (lowest → highest)
1. `default` value in variable block
2. `.auto.pkrvars.hcl` / `.auto.pkrvars.json` files
3. `-var-file=` flag
4. `-var` flag
5. `PKR_VAR_*` environment variables

---

## Plugin Version Conflicts

### Symptoms
```
Error: Incompatible plugin version

  Could not find a compatible version for plugin "github.com/hashicorp/amazon".
  Required: >= 1.3.0, < 2.0.0
  Installed: 1.2.8
```
or
```
Error: Missing plugin

  Missing required plugin: github.com/hashicorp/docker >= 1.1.0
  Run 'packer init' to install required plugins.
```
or (v1.11+)
```
Error: Missing SHA256SUM file

  Plugin github.com/hashicorp/amazon v1.3.0 is missing its SHA256SUM file.
```

### Fixes

**1. Install/upgrade plugins**
```bash
# Install required plugins
packer init .

# Force upgrade to latest compatible version
packer init -upgrade .

# Install a specific plugin manually
packer plugins install github.com/hashicorp/amazon 1.3.2
```

**2. Pin exact versions in CI**
```hcl
packer {
  required_plugins {
    amazon = {
      version = "= 1.3.2"     # Exact pin for CI reproducibility
      source  = "github.com/hashicorp/amazon"
    }
  }
}
```

**3. Fix SHA256SUM issues (v1.11+)**
```bash
# Regenerate checksums
packer plugins install github.com/hashicorp/amazon

# Or remove and reinstall
rm -rf ~/.config/packer/plugins/github.com/hashicorp/amazon
packer init .
```

**4. Plugin directory issues**
```bash
# Default plugin directory
ls ~/.config/packer/plugins/

# Override with env var
export PACKER_PLUGIN_PATH="/opt/packer/plugins"

# Check which plugins are installed
packer plugins installed
```

**5. Multiple Packer versions on same machine**
```bash
# Each Packer version may need different plugin versions
# Use separate plugin directories per project
export PACKER_PLUGIN_PATH="$(pwd)/.packer.d/plugins"
packer init .
```

**6. Custom plugin not found**
```bash
# Install from local binary
packer plugins install --path ./packer-plugin-mycloud github.com/myorg/mycloud

# Verify it's installed
packer plugins installed | grep mycloud
```

---

## Rate Limiting from Cloud Providers

### Symptoms
```
==> amazon-ebs.ubuntu: Error creating AMI: RequestLimitExceeded
==> amazon-ebs.ubuntu: Error describing instances: Throttling
==> azure-arm.ubuntu: Error: StatusCode=429
==> googlecompute.ubuntu: Error 403: Rate Limit Exceeded
```

### AWS Rate Limiting

```hcl
source "amazon-ebs" "app" {
  # Reduce API calls with polling config
  aws_polling {
    delay_seconds = 30     # Default: 2s — increase significantly
    max_attempts  = 120    # More attempts with longer delays
  }

  # Limit concurrent builds
  # Run: packer build -parallel-builds=1 .
}
```

```bash
# Reduce parallel builds
packer build -parallel-builds=1 .

# Stagger multiple packer runs
for template in templates/*.pkr.hcl; do
  packer build "$template"
  sleep 60  # Cool-down between builds
done
```

### Azure Rate Limiting

```hcl
source "azure-arm" "ubuntu" {
  # Azure-specific polling
  async_resourcegroup_delete = true  # Don't wait for RG deletion
  polling_duration_timeout   = "30m"
}
```

### GCP Rate Limiting

```hcl
source "googlecompute" "ubuntu" {
  # Use a dedicated service account with higher quotas
  account_file = "sa-packer.json"

  # Increase wait times
  state_timeout = "15m"
}
```

### General Strategies

1. **Reduce parallel builds**: `-parallel-builds=1` or `-parallel-builds=2`
2. **Increase polling intervals**: use `aws_polling.delay_seconds`
3. **Run during off-peak hours**: schedule CI builds outside business hours
4. **Use dedicated service accounts**: isolate Packer API calls from other workloads
5. **Request quota increases**: contact cloud provider for higher API limits
6. **Cache AMI lookups**: use `source_ami` instead of `source_ami_filter` if AMI is known
7. **Reduce region copies**: build in one region, copy during off-peak

---

## Quick Diagnostics Checklist

### Enable Full Debug Logging

```bash
# Set before any packer command
export PACKER_LOG=1
export PACKER_LOG_PATH="packer-debug.log"
packer build .

# Search logs for specific issues
grep -i "error\|fail\|timeout\|denied" packer-debug.log
```

### Common Pre-Flight Checks

```bash
# 1. Validate template syntax
packer validate .

# 2. Check formatting
packer fmt -check -diff .

# 3. Inspect template structure
packer inspect .

# 4. Verify plugins
packer plugins installed

# 5. Check cloud credentials
aws sts get-caller-identity          # AWS
az account show                      # Azure
gcloud auth application-default print-access-token  # GCP

# 6. Check Packer version
packer version

# 7. Test with -on-error=ask
packer build -on-error=ask .
```

### Build Failure Quick Reference

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| `Timeout waiting for SSH` | SG, subnet, or cloud-init | Check SG rules, add `pause_before_connecting` |
| `Permission denied (publickey)` | Wrong SSH user | Check AMI → username mapping table above |
| `Script exited with non-zero` | Provisioner script bug | Use `-on-error=ask`, SSH in to debug |
| `RequestLimitExceeded` | API throttling | Increase polling delay, reduce parallel builds |
| `Missing SHA256SUM` | Plugin v1.11+ | Run `packer plugins install` to regenerate |
| `Incompatible plugin` | Version mismatch | Run `packer init -upgrade .` |
| `AMI name already in use` | Duplicate name | Add `{{timestamp}}` or `force_deregister = true` |
| `context deadline exceeded` | Build timeout | Increase builder timeout settings |
| `Cannot connect to Docker daemon` | Docker not running | `sudo systemctl start docker` |

---

## Debugging Techniques Deep Dive

### The -debug flag

The `-debug` flag pauses Packer after each step and prompts to continue. It also disables parallel builds.

```bash
packer build -debug .
```

**What -debug does:**
1. Pauses before connecting to the instance.
2. Saves the SSH private key to the current directory (for manual SSH).
3. Pauses after each provisioner.
4. Pauses before cleanup.

**Use cases:**
- SSH into the instance manually between steps to inspect state.
- Check file permissions, installed packages, or service status mid-build.
- Debug provisioner scripts that fail silently.

```bash
# During a -debug pause, SSH into the instance:
ssh -i ec2_amazon-ebs.pem ubuntu@<instance-ip>

# Inspect the instance, then press Enter in the Packer terminal to continue
```

### PACKER_LOG for verbose output

```bash
# Enable full debug logging to stdout
PACKER_LOG=1 packer build .

# Write debug log to file (keeps terminal clean)
PACKER_LOG=1 PACKER_LOG_PATH=debug.log packer build .

# Then search the log for specific issues
grep -i "error\|fail\|timeout\|refused" debug.log
grep "SSH\|communicator" debug.log    # SSH connection issues
grep "API\|request\|response" debug.log  # Cloud API issues
```

### -on-error flag options

```bash
# Pause on error (interactive debugging)
packer build -on-error=ask .
# Options when error occurs: [a]bort, [c]lean up, [r]etry

# Always abort on error (for CI — no cleanup, instance stays for debugging)
packer build -on-error=abort .

# Always clean up on error (default behavior)
packer build -on-error=cleanup .

# Run only specific provisioner for debugging
packer build -on-error=ask -only='amazon-ebs.main' .
```

### Breakpoint provisioner

Insert breakpoints in your build to pause and inspect:

```hcl
build {
  sources = ["source.amazon-ebs.main"]

  provisioner "shell" {
    inline = ["apt-get update && apt-get install -y nginx"]
  }

  # BREAKPOINT — pauses here for manual inspection
  provisioner "breakpoint" {
    disable = var.env == "production"  # Only pause in dev
    note    = "Inspect nginx installation. SSH in and verify."
  }

  provisioner "shell" {
    inline = ["systemctl enable nginx"]
  }
}
```

### Error cleanup provisioner

Run diagnostics when a build fails:

```hcl
build {
  sources = ["source.amazon-ebs.main"]

  provisioner "shell" {
    inline = ["some-command-that-might-fail"]
  }

  # This ONLY runs if the build fails
  error-cleanup-provisioner "shell" {
    inline = [
      "echo '=== FAILURE DIAGNOSTICS ==='",
      "echo '--- Last 50 lines of syslog ---'",
      "sudo tail -50 /var/log/syslog 2>/dev/null || true",
      "echo '--- systemd failed units ---'",
      "systemctl --failed 2>/dev/null || true",
      "echo '--- Disk usage ---'",
      "df -h",
      "echo '--- Memory ---'",
      "free -h",
      "echo '--- Recent journal entries ---'",
      "sudo journalctl --no-pager -n 100 2>/dev/null || true",
    ]
  }
}
```

### Packer console for expression debugging

```bash
# Open interactive console to test expressions
packer console .

# Test expressions:
> formatdate("YYYYMMDD-hhmm", timestamp())
"20240115-1430"

> upper("hello-world")
"HELLO-WORLD"

> can(regex("^ami-", "ami-12345"))
true
```

---

## Disk Space Issues

### Symptoms

```
==> amazon-ebs.main: E: You don't have enough free space in /var/cache/apt/archives/
==> amazon-ebs.main: No space left on device
==> amazon-ebs.main: write /tmp/script_1234.sh: no space left on device
```

### Root Causes and Fixes

**1. Root volume too small for build operations**

```hcl
source "amazon-ebs" "main" {
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30   # Increase from default (8GB is too small)
    volume_type           = "gp3"
    delete_on_termination = true
  }
}
```

**2. Package cache filling disk during provisioning**

```bash
# Clean as you go in provisioner scripts
apt-get update -y
apt-get install -y package1 package2
apt-get clean                        # Remove downloaded .deb files
rm -rf /var/lib/apt/lists/*          # Remove package lists
rm -rf /tmp/*                        # Clean temp files
```

**3. Large files left by build tools**

```bash
# Common disk hogs to clean before finalizing
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /var/cache/*
rm -rf /var/log/*.gz /var/log/*.1    # Old rotated logs
journalctl --vacuum-size=10M         # Trim journal
docker system prune -af 2>/dev/null  # If Docker was installed
pip cache purge 2>/dev/null          # Python cache
npm cache clean --force 2>/dev/null  # Node cache
```

**4. /tmp filling up during provisioning**

```hcl
# Packer uploads scripts to /tmp by default
# If /tmp is a small tmpfs, use a different directory
provisioner "shell" {
  remote_folder = "/var/tmp"  # Use /var/tmp instead of /tmp
  scripts       = ["scripts/big-install.sh"]
}
```

**5. Monitor disk during build (add this as first provisioner for debugging)**

```hcl
provisioner "shell" {
  inline = [
    "echo '=== Disk usage at build start ==='",
    "df -h",
    "echo '=== Largest directories ==='",
    "du -sh /* 2>/dev/null | sort -rh | head -10"
  ]
}
```

---

## Authentication and Credential Problems

### AWS authentication failures

```
==> amazon-ebs.main: Error querying AMI: AuthFailure: AWS was not able to validate the provided access credentials
```

**Fix: Verify credentials are valid and have required permissions**

```bash
# Test AWS credentials
aws sts get-caller-identity

# Required IAM permissions for Packer AMI builds:
# ec2:AttachVolume, ec2:AuthorizeSecurityGroupIngress, ec2:CopyImage,
# ec2:CreateImage, ec2:CreateKeypair, ec2:CreateSecurityGroup,
# ec2:CreateSnapshot, ec2:CreateTags, ec2:CreateVolume,
# ec2:DeleteKeypair, ec2:DeleteSecurityGroup, ec2:DeleteSnapshot,
# ec2:DeleteVolume, ec2:DeregisterImage, ec2:DescribeImageAttribute,
# ec2:DescribeImages, ec2:DescribeInstances, ec2:DescribeInstanceStatus,
# ec2:DescribeRegions, ec2:DescribeSecurityGroups, ec2:DescribeSnapshots,
# ec2:DescribeSubnets, ec2:DescribeTags, ec2:DescribeVolumes,
# ec2:DetachVolume, ec2:GetPasswordData, ec2:ModifyImageAttribute,
# ec2:ModifyInstanceAttribute, ec2:ModifySnapshotAttribute,
# ec2:RegisterImage, ec2:RunInstances, ec2:StopInstances,
# ec2:TerminateInstances
```

**Minimal IAM policy for Packer:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume", "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CopyImage", "ec2:CreateImage", "ec2:CreateKeypair",
        "ec2:CreateSecurityGroup", "ec2:CreateSnapshot", "ec2:CreateTags",
        "ec2:CreateVolume", "ec2:DeleteKeypair", "ec2:DeleteSecurityGroup",
        "ec2:DeleteSnapshot", "ec2:DeleteVolume", "ec2:DeregisterImage",
        "ec2:Describe*", "ec2:DetachVolume", "ec2:GetPasswordData",
        "ec2:ModifyImageAttribute", "ec2:ModifyInstanceAttribute",
        "ec2:ModifySnapshotAttribute", "ec2:RegisterImage",
        "ec2:RunInstances", "ec2:StopInstances", "ec2:TerminateInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

### Azure authentication issues

```
==> azure-arm.main: Error getting token: AADSTS7000215: Invalid client secret provided
```

**Fixes:**

```bash
# Verify Azure CLI auth
az account show

# Check service principal credentials
az ad sp show --id $ARM_CLIENT_ID

# For managed identity, ensure the VM has the identity assigned
# For OIDC (GitHub Actions), verify the federated credential config

# Common env vars for Azure:
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."
export ARM_SUBSCRIPTION_ID="..."
export ARM_TENANT_ID="..."
```

### GCP authentication issues

```
==> googlecompute.main: Error getting credentials: google: could not find default credentials
```

**Fixes:**

```bash
# Option 1: Service account key file
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"

# Option 2: Application default credentials
gcloud auth application-default login

# Option 3: In the Packer template
source "googlecompute" "main" {
  account_file = "/path/to/key.json"
  # or
  # credentials_json = var.gcp_credentials  # JSON string
}

# Verify auth
gcloud auth list
gcloud projects list
```

### Token expiration during long builds

```
==> amazon-ebs.main: Error creating AMI: RequestExpired: Request has expired
```

**Fix: Use IAM roles instead of access keys for long builds**

```hcl
# If building on an EC2 instance, use instance profile (no expiring tokens)
source "amazon-ebs" "main" {
  # Don't set access_key/secret_key — Packer uses instance profile automatically
}

# If using assume_role, increase session duration
source "amazon-ebs" "main" {
  assume_role {
    role_arn        = "arn:aws:iam::123456789012:role/PackerRole"
    session_name    = "packer"
    duration_seconds = 7200  # 2 hours (default is 1 hour)
  }
}
```

---

## Slow Build Optimization

### Diagnosis: Where is time spent?

```bash
# Enable timestamps to see duration of each step
packer build -timestamp-ui .

# Full timing breakdown
PACKER_LOG=1 packer build . 2>&1 | grep -E "^\d{4}" | head -50
```

### Optimization techniques

**1. Use spot instances (60-90% cheaper, often faster to launch)**

```hcl
source "amazon-ebs" "fast" {
  spot_price          = "auto"
  spot_instance_types = ["t3.medium", "t3a.medium", "m5.large"]
}
```

**2. Use a larger instance type for faster provisioning**

```hcl
source "amazon-ebs" "fast" {
  instance_type = "c5.xlarge"  # More CPU = faster compiles, installs
  ebs_optimized = true

  launch_block_device_mappings {
    volume_type = "gp3"
    iops        = 6000      # More IOPS = faster disk I/O
    throughput  = 400       # More throughput
  }
}
```

**3. Optimize package installation**

```bash
# BAD — installs one at a time (slow)
apt-get install -y package1
apt-get install -y package2
apt-get install -y package3

# GOOD — install all at once
apt-get install -y package1 package2 package3

# BETTER — use local mirror or cache
apt-get install -y --no-install-recommends package1 package2 package3

# Use apt proxy/cache for repeated builds
# In provisioner: export http_proxy=http://apt-cache:3142
```

**4. Use layered images to avoid rebuilding everything**

```
Base image (monthly): 20 min build — OS patches, base packages
Platform image (weekly): 5 min build — monitoring, runtime
App image (per deploy): 2 min build — just copy binary
```

**5. Parallel builds with -parallel-builds**

```bash
# Build all targets in parallel (default)
packer build .

# Limit to 2 parallel builds (if hitting API limits)
packer build -parallel-builds=2 .
```

**6. Reduce AMI copy time**

```hcl
# Only copy to regions you actually need
ami_regions = ["us-west-2"]  # Don't copy to 10 regions if you only use 2

# Encrypted copies are slower — only encrypt in production
encrypt_boot = var.env == "production"
```

**7. Skip unnecessary steps in dev builds**

```hcl
provisioner "shell" {
  # Skip security scan in dev
  inline = var.env == "production" ? [
    "curl -sfL https://... | sudo sh",
    "sudo trivy rootfs --severity CRITICAL --exit-code 1 /"
  ] : ["echo 'Skipping security scan in dev'"]
}
```

**8. Build time comparison checklist**

| Optimization | Typical Savings |
|-------------|----------------|
| Spot instances | 60-90% cost reduction |
| c5.xlarge vs t3.micro | 3-5x faster provisioning |
| gp3 with 6000 IOPS | 2x faster disk operations |
| Layered images | 80% less rebuild time |
| `--no-install-recommends` | 30-50% faster apt installs |
| Regional mirror for packages | 2-5x faster downloads |
| Skip security scan in dev | 2-5 min saved per build |
| Fewer AMI region copies | 5-15 min saved per region |
