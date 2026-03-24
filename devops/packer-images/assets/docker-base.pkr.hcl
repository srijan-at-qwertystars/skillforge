# =============================================================================
# docker-base.pkr.hcl — Docker image template with multi-stage provisioning
#
# Features:
#   - Multi-stage shell provisioners for layered builds
#   - docker-tag and docker-push post-processors
#   - Chained post-processors for tag → push workflow
#   - Environment-based configuration
#   - Health check and metadata via OCI labels
#
# Usage:
#   packer init .
#   packer validate -var-file=docker.pkrvars.hcl .
#   packer build -var-file=docker.pkrvars.hcl .
# =============================================================================

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    docker = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/docker"
    }
  }
}

# --- Variables ---

variable "registry" {
  type        = string
  default     = "docker.io"
  description = "Container registry URL"
}

variable "repository" {
  type        = string
  default     = "myorg/myapp"
  description = "Image repository name"
}

variable "version" {
  type        = string
  default     = "latest"
  description = "Image version tag"
}

variable "base_image" {
  type        = string
  default     = "ubuntu:22.04"
  description = "Base image to build from"
}

variable "app_port" {
  type        = number
  default     = 8080
  description = "Application port to expose"
}

variable "env" {
  type    = string
  default = "production"
}

variable "registry_user" {
  type      = string
  default   = ""
  sensitive = true
}

variable "registry_pass" {
  type      = string
  default   = ""
  sensitive = true
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

# --- Locals ---

locals {
  full_image    = "${var.registry}/${var.repository}"
  build_date    = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timestamp())
  image_version = var.version != "latest" ? var.version : formatdate("YYYYMMDD.hhmm", timestamp())
}

# --- Source ---

source "docker" "app" {
  image  = var.base_image
  commit = true

  changes = [
    "EXPOSE ${var.app_port}",
    "ENV APP_ENV=${var.env}",
    "ENV APP_PORT=${var.app_port}",
    "WORKDIR /app",
    "USER appuser",
    "ENTRYPOINT [\"/app/entrypoint.sh\"]",
    "CMD [\"--config\", \"/app/config.yaml\"]",
    "HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -f http://localhost:${var.app_port}/health || exit 1",
    "LABEL org.opencontainers.image.title=${var.repository}",
    "LABEL org.opencontainers.image.version=${local.image_version}",
    "LABEL org.opencontainers.image.created=${local.build_date}",
    "LABEL org.opencontainers.image.revision=${var.git_sha}",
    "LABEL org.opencontainers.image.source=https://github.com/${var.repository}"
  ]
}

# --- Build ---

build {
  sources = ["source.docker.app"]

  # Stage 1: System dependencies
  provisioner "shell" {
    inline = [
      "echo '==> Stage 1: System dependencies'",
      "apt-get update -y",
      "apt-get install -y --no-install-recommends curl ca-certificates tini",
      "rm -rf /var/lib/apt/lists/*"
    ]
  }

  # Stage 2: Application user and directories
  provisioner "shell" {
    inline = [
      "echo '==> Stage 2: Application setup'",
      "groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser",
      "mkdir -p /app/config /app/data /app/logs",
      "chown -R appuser:appuser /app"
    ]
  }

  # Stage 3: Application files
  provisioner "file" {
    source      = "app/"
    destination = "/tmp/app/"
  }

  provisioner "shell" {
    inline = [
      "echo '==> Stage 3: Installing application'",
      "cp -r /tmp/app/* /app/ 2>/dev/null || echo 'No app files to copy'",
      "rm -rf /tmp/app"
    ]
  }

  # Stage 4: Entrypoint script
  provisioner "shell" {
    inline = [
      "cat > /app/entrypoint.sh <<'ENTRY'",
      "#!/bin/sh",
      "set -e",
      "echo \"Starting application (env=$APP_ENV, port=$APP_PORT)\"",
      "exec \"$@\"",
      "ENTRY",
      "chmod +x /app/entrypoint.sh",
      "chown appuser:appuser /app/entrypoint.sh"
    ]
  }

  # Stage 5: Cleanup and hardening
  provisioner "shell" {
    inline = [
      "echo '==> Stage 5: Cleanup and hardening'",
      "apt-get purge -y --auto-remove gcc g++ make",
      "rm -rf /var/lib/apt/lists/* /var/cache/apt/*",
      "rm -rf /tmp/* /var/tmp/*",
      "rm -f /root/.bash_history",
      "find / -name '*.pyc' -delete 2>/dev/null || true",
      "find / -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true",
      "chown -R appuser:appuser /app"
    ]
  }

  # Post-processors: tag and push (sequential chain)
  post-processors {
    post-processor "docker-tag" {
      repository = local.full_image
      tags       = [local.image_version, "latest"]
    }

    post-processor "docker-push" {
      login          = var.registry_user != "" ? true : false
      login_server   = var.registry
      login_username = var.registry_user
      login_password = var.registry_pass
    }
  }

  # Manifest (runs in parallel with tag+push chain)
  post-processor "manifest" {
    output     = "manifests/docker-manifest.json"
    strip_path = true
    custom_data = {
      image      = "${local.full_image}:${local.image_version}"
      version    = local.image_version
      build_date = local.build_date
      git_sha    = var.git_sha
    }
  }
}
