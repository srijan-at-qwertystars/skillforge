# Cloud Builder Deep Dive

## Table of Contents

- [Amazon EBS Builder](#amazon-ebs-builder)
  - [Launch Configuration](#launch-configuration)
  - [EBS Optimization](#ebs-optimization)
  - [AMI Encryption](#ami-encryption)
  - [Cross-Account Sharing](#cross-account-sharing)
  - [Multi-Region Distribution](#multi-region-distribution)
  - [Spot Instance Builds](#spot-instance-builds)
  - [SSM Session Manager (No SSH)](#ssm-session-manager-no-ssh)
  - [source_ami_filter Best Practices](#source_ami_filter-best-practices)
- [Azure Builder](#azure-builder)
  - [Managed Images](#managed-images)
  - [Shared Image Gallery](#shared-image-gallery)
  - [Specialized vs Generalized Images](#specialized-vs-generalized-images)
  - [Authentication Methods](#authentication-methods)
  - [Azure Build Networking](#azure-build-networking)
- [GCP Builder](#gcp-builder)
  - [Image Families](#image-families)
  - [Shared VPC Builds](#shared-vpc-builds)
  - [Shielded VM Images](#shielded-vm-images)
  - [Image Sharing Across Projects](#image-sharing-across-projects)
  - [Nested Virtualization](#nested-virtualization)
- [Docker Builder](#docker-builder)
  - [Commit vs Export Mode](#commit-vs-export-mode)
  - [Multi-Stage Provisioning](#multi-stage-provisioning)
  - [Registry Authentication](#registry-authentication)
  - [OCI Image Labels](#oci-image-labels)
  - [Volume Mounts During Build](#volume-mounts-during-build)
  - [Packer Docker vs Dockerfile](#packer-docker-vs-dockerfile)
- [Cross-Builder Patterns](#cross-builder-patterns)
  - [Single Template Multi-Cloud](#single-template-multi-cloud)
  - [Builder-Specific Overrides](#builder-specific-overrides)
  - [Conditional Builder Selection](#conditional-builder-selection)

---

## Amazon EBS Builder

The `amazon-ebs` builder is the most commonly used Packer builder. It launches an EC2 instance, provisions it, creates an AMI snapshot, and terminates the instance.

### Launch Configuration

#### Full source block with all production knobs

```hcl
source "amazon-ebs" "production" {
  region        = var.aws_region
  instance_type = var.instance_type
  ami_name      = "${var.ami_prefix}-${local.timestamp}"
  ssh_username  = "ubuntu"

  # AMI source — always use filter, never hardcode IDs
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      architecture        = "x86_64"
    }
    most_recent = true
    owners      = ["099720109477"]  # Canonical
  }

  # Networking — use session manager or specify VPC
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id
  associate_public_ip_address = true
  temporary_security_group_source_cidrs = [var.allowed_cidr]

  # Instance metadata — require IMDSv2 (security best practice)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  # SSH tuning
  ssh_timeout            = "10m"
  ssh_handshake_attempts = 50
  pause_before_connecting = "10s"

  # Shutdown behavior
  shutdown_behavior       = "terminate"
  disable_stop_instance   = false

  # IAM instance profile for builds that need AWS API access
  iam_instance_profile = var.build_instance_profile

  # Run tags (applied to build instance, not the AMI)
  run_tags = {
    Name    = "packer-build-${var.ami_prefix}"
    Purpose = "packer-build"
    TTL     = "2h"
  }

  tags          = local.common_tags
  snapshot_tags = local.common_tags
}
```

#### Using assume_role for cross-account builds

```hcl
source "amazon-ebs" "cross_account" {
  region = "us-east-1"

  # Build in account A, create AMI in account B
  assume_role {
    role_arn     = "arn:aws:iam::123456789012:role/PackerBuildRole"
    session_name = "packer-build"
    external_id  = var.external_id
  }

  # ... rest of configuration
}
```

### EBS Optimization

#### Volume configuration for performance

```hcl
source "amazon-ebs" "optimized" {
  # Root volume — gp3 with tuned IOPS
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    iops                  = 4000     # gp3: 3000-16000 (free up to 3000)
    throughput            = 250      # gp3: 125-1000 MB/s (free up to 125)
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.kms_key_id  # Custom KMS key
  }

  # Additional data volume
  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_size           = 100
    volume_type           = "gp3"
    iops                  = 6000
    throughput            = 400
    delete_on_termination = true
    encrypted             = true
  }

  # AMI block device mappings (what appears in the final AMI)
  ami_block_device_mappings {
    device_name  = "/dev/sdf"
    volume_size  = 100
    volume_type  = "gp3"
    encrypted    = true
  }

  # Enable EBS optimization on the build instance
  ebs_optimized = true
}
```

#### Fast snapshot restores for high-IOPS AMIs

```hcl
source "amazon-ebs" "fast_launch" {
  # Enable fast snapshot restore in target regions
  fast_launch {
    enable_fast_launch = true
    target_resource_count = 5  # Pre-provisioned snapshots
  }

  # Copy to regions with fast launch
  ami_regions = ["us-west-2", "eu-west-1"]
}
```

### AMI Encryption

```hcl
source "amazon-ebs" "encrypted" {
  # Encrypt the boot volume during build
  encrypt_boot = true

  # Use a specific KMS key (omit for default aws/ebs key)
  kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/abcd-1234"

  # For cross-region copies, specify per-region KMS keys
  region_kms_key_ids = {
    "us-west-2" = "arn:aws:kms:us-west-2:123456789012:key/efgh-5678"
    "eu-west-1" = "arn:aws:kms:eu-west-1:123456789012:key/ijkl-9012"
  }

  # Encrypt the build volume (separate from AMI encryption)
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    encrypted   = true
    kms_key_id  = var.build_kms_key
    # ...
  }
}
```

**Key points:**
- `encrypt_boot = true` encrypts the AMI snapshots; the build volume can be unencrypted.
- Cross-account sharing of encrypted AMIs requires granting the target account access to the KMS key.
- Re-encrypting an AMI with a different key requires a copy operation (Packer does this automatically with `region_kms_key_ids`).

### Cross-Account Sharing

```hcl
source "amazon-ebs" "shared" {
  # Share with specific AWS accounts
  ami_users = ["111111111111", "222222222222"]

  # Share with specific organizations
  ami_org_arns = ["arn:aws:organizations::123456789012:organization/o-abc123"]

  # Share with specific OUs
  ami_ou_arns = ["arn:aws:organizations::123456789012:ou/o-abc123/ou-def456"]

  # Make the AMI public (rarely appropriate)
  # ami_groups = ["all"]

  # For encrypted AMIs, grant KMS key access via policy:
  # The target account needs kms:Decrypt and kms:CreateGrant on the key.
}
```

#### Snapshot sharing for encrypted AMIs

When sharing encrypted AMIs cross-account, the KMS key policy must allow the target account:

```json
{
  "Sid": "AllowTargetAccountDecrypt",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::222222222222:root" },
  "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant", "kms:ReEncryptFrom"],
  "Resource": "*"
}
```

### Multi-Region Distribution

```hcl
source "amazon-ebs" "multi_region" {
  region      = "us-east-1"              # Primary build region
  ami_regions = var.distribution_regions  # Copy AMI to these regions

  # Copy concurrency (default: no limit; set to avoid API throttling)
  # Packer copies to all regions in parallel by default

  # Tags applied to copied AMIs too
  tags          = local.common_tags
  snapshot_tags = local.common_tags

  # Skip creating AMI in specific regions if it already exists
  force_deregister      = true
  force_delete_snapshot  = true
}
```

**Optimization tips:**
- Build in the region closest to your provisioning resources (e.g., package mirrors).
- Use `ami_regions` instead of building in multiple regions — copy is faster than rebuild.
- Encrypted AMI copies re-encrypt with the target region's key (set via `region_kms_key_ids`).

### Spot Instance Builds

```hcl
source "amazon-ebs" "spot_build" {
  # Fixed spot price cap
  spot_price = "0.05"

  # Or auto-bid at on-demand price (recommended)
  spot_price = "auto"

  # Fleet of instance types for better spot availability
  spot_instance_types = [
    "t3.medium", "t3a.medium",
    "m5.large", "m5a.large", "m5d.large",
    "c5.large", "c5a.large"
  ]

  # Spot-specific settings
  spot_tags = { Purpose = "packer-spot-build" }

  # If spot is interrupted, retry or fail gracefully
  # Packer will terminate and error if spot is reclaimed
}
```

**When NOT to use spot:**
- Windows builds with long provisioning (risk of interruption during sysprep).
- Builds that modify external state (database migrations in provisioners).
- Compliance environments requiring deterministic infrastructure.

### SSM Session Manager (No SSH)

Build without opening SSH port 22 — all communication via AWS SSM:

```hcl
source "amazon-ebs" "ssm" {
  communicator = "ssh"
  ssh_username = "ubuntu"

  # Use SSM tunnel instead of direct SSH
  ssh_interface = "session_manager"

  # The build instance needs the SSM agent and an instance profile
  iam_instance_profile = "PackerSSMRole"

  # No need for public IP or security group SSH ingress
  associate_public_ip_address = false
  # No temporary_security_group_source_cidrs needed
}
```

**Requirements:**
- The instance profile must have `AmazonSSMManagedInstanceCore` policy.
- AWS Session Manager plugin must be installed on the build machine.
- The build instance needs outbound internet (or VPC endpoints for SSM).

### source_ami_filter Best Practices

```hcl
# Look up the latest AMI dynamically at build time
source_ami_filter {
  filters = {
    # Be specific with the name pattern
    name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "x86_64"
    state               = "available"
  }
  most_recent = true
  owners      = ["099720109477"]  # ALWAYS specify owners
}
```

**Common owner IDs:**
| Owner | Account ID |
|-------|-----------|
| Canonical (Ubuntu) | `099720109477` |
| Amazon Linux | `137112412989` or `amazon` |
| Red Hat | `309956199498` |
| Debian | `136693071363` |
| CentOS | `125523088429` |
| Self (your account) | `self` |

**Anti-pattern — never hardcode AMI IDs:**
```hcl
# BAD — this AMI will eventually be deprecated
source_ami = "ami-0abcdef1234567890"

# GOOD — always resolves to the latest
source_ami_filter { ... most_recent = true }
```

---

## Azure Builder

### Managed Images

```hcl
source "azure-arm" "ubuntu" {
  # Authentication (service principal or managed identity)
  subscription_id = var.azure_subscription_id
  client_id       = var.azure_client_id
  client_secret   = var.azure_client_secret
  tenant_id       = var.azure_tenant_id

  # Managed image output
  managed_image_resource_group_name = var.resource_group
  managed_image_name                = "${var.image_prefix}-${local.timestamp}"

  # Source image
  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "0001-com-ubuntu-server-jammy"
  image_sku       = "22_04-lts-gen2"
  location        = var.azure_location
  vm_size         = "Standard_B2s"

  # Disk
  os_disk_size_gb = 30
  disk_caching_type = "ReadWrite"

  # Networking — build in existing VNET
  virtual_network_name                = var.vnet_name
  virtual_network_subnet_name         = var.subnet_name
  virtual_network_resource_group_name = var.network_rg
  private_virtual_network_with_public_ip = false

  ssh_username = "packer"

  # Tags
  azure_tags = local.common_tags
}
```

#### Using managed identity (no secrets needed):

```hcl
source "azure-arm" "managed_id" {
  subscription_id = var.azure_subscription_id
  # No client_id/secret/tenant — uses VM's managed identity
  use_azure_cli_auth = true  # or set in env

  # ...
}
```

### Shared Image Gallery

Shared Image Gallery (now "Azure Compute Gallery") enables versioned image distribution across subscriptions and regions.

```hcl
source "azure-arm" "gallery" {
  subscription_id = var.azure_subscription_id

  # Output to Shared Image Gallery instead of managed image
  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.gallery_rg
    gallery_name         = var.gallery_name
    image_name           = var.image_definition
    image_version        = local.image_version
    replication_regions  = ["eastus", "westus2", "westeurope"]
    storage_account_type = "Standard_LRS"  # or Premium_LRS
  }

  # Source from existing gallery image (layered builds)
  shared_image_gallery {
    subscription   = var.azure_subscription_id
    resource_group = var.gallery_rg
    gallery_name   = var.gallery_name
    image_name     = "base-ubuntu"
    image_version  = "latest"  # or specific version
  }

  # ...
}
```

**Gallery hierarchy:** Gallery → Image Definition → Image Version

### Specialized vs Generalized Images

```hcl
build {
  sources = ["source.azure-arm.ubuntu"]

  # For GENERALIZED images (default) — can create new VMs
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
      "# Your provisioning here",
      "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"
    ]
  }

  # For SPECIALIZED images — skip deprovisioning
  # Set in the source block:
  #   capture_name_prefix  = "specialized"
  #   capture_container_name = "images"
}
```

**Generalized:** Runs sysprep/deprovision; creates new unique VMs. Use for templates.
**Specialized:** Exact clone of source VM state. Use for disaster recovery or dev copies.

### Authentication Methods

```hcl
# Method 1: Service principal (CI/CD)
source "azure-arm" "sp" {
  client_id       = var.client_id
  client_secret   = var.client_secret
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Method 2: Azure CLI (interactive / local dev)
source "azure-arm" "cli" {
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id
}

# Method 3: Managed identity (from Azure VM/container)
# Just set subscription_id — Packer auto-detects managed identity

# Method 4: OIDC / Federated credentials (GitHub Actions)
source "azure-arm" "oidc" {
  client_id       = var.client_id
  oidc_request_url  = var.oidc_url    # ACTIONS_ID_TOKEN_REQUEST_URL
  oidc_request_token = var.oidc_token # ACTIONS_ID_TOKEN_REQUEST_TOKEN
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
```

### Azure Build Networking

```hcl
source "azure-arm" "private" {
  # Build in a specific VNET/subnet — no public IP
  virtual_network_name                = "packer-vnet"
  virtual_network_subnet_name         = "packer-subnet"
  virtual_network_resource_group_name = "networking-rg"

  # No public IP — requires network line-of-sight (VPN, peering, private endpoint)
  private_virtual_network_with_public_ip = false

  # Or allow public IP on private VNET (for NAT-less builds)
  private_virtual_network_with_public_ip = true

  # Allowed inbound IP for temp NSG (if using public IP)
  allowed_inbound_ip_addresses = [var.build_machine_ip]
}
```

---

## GCP Builder

### Image Families

Image families provide a pointer to the latest image in a series. When a new image is created in a family, it becomes the default; when deprecated, the previous image takes over.

```hcl
source "googlecompute" "ubuntu" {
  project_id   = var.gcp_project_id
  zone         = "us-central1-a"
  machine_type = "e2-standard-2"
  ssh_username = "packer"

  # Source from an image family (always gets latest)
  source_image_family  = "ubuntu-2404-lts-amd64"
  source_image_project_id = "ubuntu-os-cloud"

  # Output image — assign to a family
  image_name        = "${var.image_prefix}-${local.timestamp}"
  image_family      = var.image_family   # e.g., "golden-ubuntu"
  image_description = "Golden Ubuntu image built ${local.timestamp}"

  # Image storage location
  image_storage_locations = ["us"]  # multi-region: us, eu, asia

  # Image labels (GCP equivalent of tags)
  image_labels = {
    environment = var.env
    managed_by  = "packer"
    build_date  = local.timestamp
    git_sha     = var.git_sha
  }

  # Disk
  disk_size = 20
  disk_type = "pd-ssd"  # pd-standard, pd-ssd, pd-balanced

  # Deprecate the previous family image automatically
  # (Packer doesn't do this; use a post-processor or gcloud)
}
```

#### Deprecating old images in a family

```bash
# After successful build, deprecate the previous image
gcloud compute images deprecate OLD_IMAGE_NAME \
  --project=my-project \
  --state=DEPRECATED \
  --replacement=NEW_IMAGE_NAME
```

### Shared VPC Builds

```hcl
source "googlecompute" "shared_vpc" {
  project_id = var.service_project_id

  # Network in the host project
  network_project_id = var.host_project_id
  network            = var.shared_vpc_network
  subnetwork         = var.shared_vpc_subnet

  # Disable external IP (requires Cloud NAT for internet access)
  omit_external_ip = true
  use_internal_ip  = true

  # IAP tunnel for SSH (alternative to external IP)
  use_iap = true

  # The Packer service account needs:
  # - compute.instanceAdmin.v1 on the service project
  # - compute.networkUser on the host project's subnet
}
```

### Shielded VM Images

```hcl
source "googlecompute" "shielded" {
  # Enable Shielded VM features
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true

  # Must use a Shielded VM compatible source image
  source_image_family     = "ubuntu-2404-lts-amd64"
  source_image_project_id = "ubuntu-os-cloud"

  # Image will inherit Shielded VM capabilities
  image_name   = "shielded-golden-${local.timestamp}"
  image_family = "shielded-golden-ubuntu"
}
```

### Image Sharing Across Projects

```hcl
source "googlecompute" "shared" {
  project_id = var.image_project_id  # Central image project

  # Build instance runs in a build project
  # but the image is created in the image project

  image_name   = "shared-golden-${local.timestamp}"
  image_family = "golden-ubuntu"
}
```

After build, grant access via IAM:

```bash
# Grant another project access to use the image
gcloud compute images add-iam-policy-binding IMAGE_NAME \
  --project=image-project \
  --member="serviceAccount:SA@consumer-project.iam.gserviceaccount.com" \
  --role="roles/compute.imageUser"

# Or grant at the project level for all images
gcloud projects add-iam-policy-binding image-project \
  --member="serviceAccount:SA@consumer-project.iam.gserviceaccount.com" \
  --role="roles/compute.imageUser"
```

### Nested Virtualization

For building VM images that themselves run VMs (e.g., Android emulators, KVM):

```hcl
source "googlecompute" "nested_virt" {
  machine_type = "n1-standard-4"  # Must be N1 or N2 for nested virt

  # Enable nested virtualization on the build instance
  enable_nested_virtualization = true

  # License for the output image to support nested virt
  image_licenses = [
    "projects/vm-options/global/licenses/enable-vmx"
  ]

  # Verify KVM is available in provisioner
  # provisioner "shell" { inline = ["ls /dev/kvm"] }
}
```

---

## Docker Builder

### Commit vs Export Mode

```hcl
# COMMIT mode — creates a Docker image via docker commit
# Use when you want to push to a registry
source "docker" "commit" {
  image  = "ubuntu:22.04"
  commit = true

  changes = [
    "EXPOSE 8080",
    "ENTRYPOINT [\"/app/start.sh\"]",
    "USER appuser"
  ]
}

# EXPORT mode — exports filesystem as a tar archive
# Use when you need a rootfs or want to import into another tool
source "docker" "export" {
  image  = "ubuntu:22.04"
  export_path = "output/rootfs.tar"
  # No changes block — changes only apply to commit mode
}

# DISCARD mode — just run provisioners, discard the result
# Use for testing provisioner scripts
source "docker" "discard" {
  image   = "ubuntu:22.04"
  discard = true
}
```

### Multi-Stage Provisioning

```hcl
source "docker" "app" {
  image  = "node:20-slim"
  commit = true

  # Dockerfile-like changes applied after commit
  changes = [
    "WORKDIR /app",
    "ENV NODE_ENV=production",
    "EXPOSE 3000",
    "USER node",
    "ENTRYPOINT [\"node\", \"server.js\"]",
    "HEALTHCHECK --interval=30s CMD curl -f http://localhost:3000/health || exit 1"
  ]
}

build {
  sources = ["source.docker.app"]

  # Stage 1: System deps
  provisioner "shell" {
    inline = [
      "apt-get update && apt-get install -y --no-install-recommends curl ca-certificates",
      "rm -rf /var/lib/apt/lists/*"
    ]
  }

  # Stage 2: Application
  provisioner "file" {
    source      = "dist/"
    destination = "/app/"
  }

  # Stage 3: Dependencies
  provisioner "shell" {
    inline = [
      "cd /app && npm ci --production",
      "chown -R node:node /app"
    ]
  }

  # Stage 4: Cleanup
  provisioner "shell" {
    inline = [
      "apt-get purge -y --auto-remove",
      "rm -rf /tmp/* /var/tmp/* /root/.npm"
    ]
  }

  # Tag and push
  post-processors {
    post-processor "docker-tag" {
      repository = "${var.registry}/${var.repository}"
      tags       = [var.version, "latest"]
    }
    post-processor "docker-push" {
      login          = true
      login_server   = var.registry
      login_username = var.registry_user
      login_password = var.registry_pass
    }
  }
}
```

### Registry Authentication

```hcl
# Docker Hub
post-processor "docker-push" {
  login          = true
  login_server   = "https://index.docker.io/v1/"
  login_username = var.dockerhub_user
  login_password = var.dockerhub_token  # Use access token, not password
}

# AWS ECR — login via aws ecr get-login-password
post-processor "docker-push" {
  ecr_login      = true
  login_server   = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# GCR / Artifact Registry
post-processor "docker-push" {
  login          = true
  login_server   = "https://us-docker.pkg.dev"
  login_username = "_json_key"
  login_password = file(var.gcp_key_file)
}

# GitHub Container Registry
post-processor "docker-push" {
  login          = true
  login_server   = "https://ghcr.io"
  login_username = var.github_user
  login_password = var.github_token
}
```

### OCI Image Labels

Standard OCI annotations for image metadata:

```hcl
source "docker" "app" {
  image  = var.base_image
  commit = true

  changes = [
    "LABEL org.opencontainers.image.title=${var.app_name}",
    "LABEL org.opencontainers.image.description=${var.app_description}",
    "LABEL org.opencontainers.image.version=${var.version}",
    "LABEL org.opencontainers.image.created=${local.build_date}",
    "LABEL org.opencontainers.image.revision=${var.git_sha}",
    "LABEL org.opencontainers.image.source=${var.repo_url}",
    "LABEL org.opencontainers.image.authors=${var.team_email}",
    "LABEL org.opencontainers.image.vendor=${var.org_name}",
    "LABEL org.opencontainers.image.licenses=Apache-2.0",
    "LABEL org.opencontainers.image.base.name=${var.base_image}",
  ]
}
```

### Volume Mounts During Build

```hcl
source "docker" "with_volumes" {
  image  = "ubuntu:22.04"
  commit = true

  # Mount host directories into the build container
  volumes = {
    "/host/path/to/artifacts" = "/build/artifacts"
    "/host/path/to/cache"     = "/var/cache/build"
  }

  # Run with elevated privileges (needed for some provisioners)
  privileged = true

  # Run specific capabilities
  cap_add = ["SYS_PTRACE", "NET_ADMIN"]
}
```

### Packer Docker vs Dockerfile

**Use Packer Docker when:**
- You need to share provisioning logic between Docker and VM images.
- You're already using Packer for VM images and want consistency.
- You need complex provisioning (Ansible, Chef, multi-step scripts).
- You want post-build steps (push to multiple registries, manifest generation).

**Use Dockerfile when:**
- You only build Docker images (no VMs).
- You need multi-stage builds with `FROM` chaining (Packer can't do this).
- You want build caching (Packer rebuilds from scratch every time).
- You need BuildKit features (secret mounts, SSH forwarding, cache mounts).
- Your CI/CD already has Docker build pipelines.

**Hybrid approach** — Use Packer to generate a base image, Dockerfile for app layer:

```hcl
# Packer: build base image with system deps
source "docker" "base" {
  image  = "ubuntu:22.04"
  commit = true
}

# Then in your Dockerfile:
# FROM myregistry/packer-base:latest
# COPY app/ /app/
# CMD ["/app/start.sh"]
```

---

## Cross-Builder Patterns

### Single Template Multi-Cloud

```hcl
# One build block, multiple cloud sources — they run in parallel
build {
  sources = [
    "source.amazon-ebs.golden",
    "source.azure-arm.golden",
    "source.googlecompute.golden",
  ]

  # Common provisioners run on all sources
  provisioner "shell" {
    inline = ["sudo apt-get update -y && sudo apt-get upgrade -y"]
  }

  # Cloud-specific provisioners via only/except
  provisioner "shell" {
    only   = ["amazon-ebs.golden"]
    inline = [
      "sudo apt-get install -y amazon-cloudwatch-agent",
      "sudo snap install amazon-ssm-agent --classic"
    ]
  }

  provisioner "shell" {
    only   = ["azure-arm.golden"]
    inline = [
      "sudo apt-get install -y walinuxagent",
      "sudo waagent -force -deprovision+user"
    ]
  }

  provisioner "shell" {
    only   = ["googlecompute.golden"]
    inline = [
      "sudo apt-get install -y google-cloud-ops-agent"
    ]
  }
}
```

### Builder-Specific Overrides

```hcl
provisioner "shell" {
  inline = ["echo 'Default provisioning for all builders'"]

  override = {
    "amazon-ebs.golden" = {
      inline = ["echo 'AWS-specific provisioning'", "sudo yum install -y aws-cli"]
    }
    "azure-arm.golden" = {
      inline = ["echo 'Azure-specific provisioning'", "sudo apt-get install -y azure-cli"]
    }
  }
}
```

### Conditional Builder Selection

At build time, use `-only` to select specific builders:

```bash
# Build only AWS
packer build -only='amazon-ebs.*' .

# Build only Azure and GCP
packer build -only='azure-arm.*' -only='googlecompute.*' .

# Exclude Docker
packer build -except='docker.*' .

# Limit parallel builds (default: unlimited)
packer build -parallel-builds=2 .
```

In CI/CD, parameterize the target:

```yaml
# GitHub Actions
- run: packer build -only='${{ inputs.cloud_provider }}.*' .
```
