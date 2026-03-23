# Periodic Batch Job — Nomad Job Template
#
# Features: periodic scheduling, parameterized dispatch, retry logic,
# artifact fetching, and resource management.
#
# This template can run as:
#   - Periodic (cron-scheduled): nomad job run batch-job.nomad.hcl
#   - Dispatched (on-demand):    nomad job dispatch batch-job -meta report_type=daily @input.json
#
# Note: Do NOT combine periodic + parameterized in the same job.
# This template shows both patterns — pick one per job.

variable "image" {
  description = "Docker image for the batch job"
  type        = string
  default     = "myorg/batch-processor:v2.0.0"
}

# ──────────────────────────────────────────────
# Option A: Periodic Batch Job (cron-scheduled)
# ──────────────────────────────────────────────

job "batch-periodic" {
  region      = "us-east-1"
  datacenters = ["dc1", "dc2"]
  type        = "batch"
  namespace   = "production"
  priority    = 40

  periodic {
    crons            = ["0 2 * * *"]     # 2 AM daily
    prohibit_overlap = true              # skip if previous run still active
    time_zone        = "UTC"
  }

  group "process" {
    count = 1

    # Prefer nodes with fast storage
    affinity {
      attribute = "${meta.storage_type}"
      value     = "ssd"
      weight    = 75
    }

    # -- Restart policy for transient failures --
    restart {
      attempts = 3
      interval = "30m"
      delay    = "15s"
      mode     = "delay"     # "delay" retries with backoff; "fail" stops after attempts
    }

    # -- Reschedule on different node if node fails --
    reschedule {
      attempts       = 2
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "10m"
      unlimited      = false
    }

    # Disk for intermediate data
    ephemeral_disk {
      size    = 2000    # 2 GB
      migrate = false
      sticky  = false
    }

    network {
      mode = "bridge"
    }

    task "etl" {
      driver = "docker"

      config {
        image   = var.image
        command = "/app/run-batch.sh"
        args    = [
          "--date", "${NOMAD_META_run_date}",
          "--output", "/alloc/data/output",
        ]

        readonly_rootfs = true
        cap_drop        = ["ALL"]

        volumes = [
          "local/config:/app/config:ro",
        ]
      }

      user = "1000:1000"

      # -- Fetch processing script artifact --
      artifact {
        source      = "https://releases.myorg.com/scripts/etl-v2.0.0.tar.gz"
        destination = "local/scripts"
        options {
          checksum = "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        }
      }

      # -- Fetch config from S3 --
      artifact {
        source      = "s3://myorg-config/batch/config.yaml"
        destination = "local/config/"
        options {
          aws_access_key_id     = ""     # uses instance profile if empty
          aws_access_secret_key = ""
        }
      }

      # -- Vault secrets for database access --
      vault {
        policies    = ["batch-db-read"]
        change_mode = "restart"
      }

      template {
        data = <<-EOF
          {{ with secret "database/creds/batch-readonly" }}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{ end }}
          DB_HOST=postgres.service.consul
          DB_NAME=analytics
          RUN_DATE={{ env "NOMAD_META_run_date" | default "auto" }}
        EOF
        destination = "secrets/db.env"
        env         = true
      }

      # Metadata defaults for periodic runs
      meta {
        run_date = "auto"    # overridden by dispatch or computed in entrypoint
      }

      resources {
        cpu    = 2000    # 2 GHz — batch jobs often need burst CPU
        memory = 1024    # 1 GB
      }

      # Kill timeout — allow graceful shutdown for long-running batches
      kill_timeout = "30s"
    }
  }
}

# ──────────────────────────────────────────────────
# Option B: Parameterized Batch Job (on-demand dispatch)
# ──────────────────────────────────────────────────────

job "batch-dispatch" {
  region      = "us-east-1"
  datacenters = ["dc1", "dc2"]
  type        = "batch"
  namespace   = "production"
  priority    = 40

  parameterized {
    payload       = "optional"
    meta_required = ["report_type"]
    meta_optional = ["customer_id", "dry_run"]
  }

  group "generate" {
    count = 1

    restart {
      attempts = 2
      interval = "15m"
      delay    = "10s"
      mode     = "delay"
    }

    reschedule {
      attempts  = 1
      interval  = "30m"
      delay     = "30s"
      unlimited = false
    }

    ephemeral_disk {
      size = 1000
    }

    network {
      mode = "bridge"
    }

    task "report" {
      driver = "docker"

      config {
        image   = "myorg/report-generator:v3.1.0"
        command = "/app/generate-report.sh"
        args    = [
          "--type", "${NOMAD_META_report_type}",
          "--customer", "${NOMAD_META_customer_id}",
          "--dry-run", "${NOMAD_META_dry_run}",
        ]
      }

      # Payload written to this file (if provided during dispatch)
      dispatch_payload {
        file = "input/payload.json"
      }

      vault {
        policies = ["report-secrets"]
      }

      template {
        data = <<-EOF
          {{ with secret "secret/data/reports/config" }}
          S3_BUCKET={{ .Data.data.output_bucket }}
          SMTP_HOST={{ .Data.data.smtp_host }}
          {{ end }}
        EOF
        destination = "secrets/config.env"
        env         = true
      }

      # Default values for optional meta
      meta {
        customer_id = "all"
        dry_run     = "false"
      }

      resources {
        cpu    = 1000
        memory = 512
      }

      kill_timeout = "60s"
    }
  }
}
