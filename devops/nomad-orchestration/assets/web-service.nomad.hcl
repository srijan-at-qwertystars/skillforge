# Production Web Service — Nomad Job Template
#
# Features: rolling deploy with canary, Consul service mesh, Vault secrets,
# health checks, resource limits, spread scheduling, and auto-revert.
#
# Usage: nomad job run web-service.nomad.hcl
# Customize: Replace values in CAPS with your actual configuration.

variable "image" {
  description = "Docker image for the web service"
  type        = string
  default     = "myorg/web-service:v1.0.0"
}

variable "count" {
  description = "Number of instances"
  type        = number
  default     = 3
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

job "web-service" {
  region      = "us-east-1"
  datacenters = ["dc1", "dc2"]
  type        = "service"
  namespace   = var.environment
  priority    = 75

  # -- Deployment strategy: canary + rolling --
  update {
    max_parallel     = 1
    min_healthy_time = "30s"
    healthy_deadline = "5m"
    progress_deadline = "10m"
    auto_revert      = true
    auto_promote     = false     # manual canary promotion
    canary           = 1
  }

  # -- Reschedule on failure --
  reschedule {
    attempts       = 3
    interval       = "30m"
    delay          = "15s"
    delay_function = "exponential"
    max_delay      = "5m"
    unlimited      = false
  }

  # -- Migrate during node drain --
  migrate {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "15s"
    healthy_deadline = "5m"
  }

  group "web" {
    count = var.count

    # -- Spread across datacenters for resilience --
    spread {
      attribute = "${node.datacenter}"
    }

    # -- Ensure distinct hosts --
    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    constraint {
      attribute = "${attr.kernel.name}"
      value     = "linux"
    }

    # -- Networking: bridge mode with Consul Connect --
    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }

      port "metrics" {
        to = 9090
      }
    }

    # -- Primary service with health checks --
    service {
      name     = "web-service"
      port     = "http"
      provider = "consul"
      tags     = ["v1", var.environment, "traefik.enable=true"]

      check {
        name     = "http-health"
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"

        check_restart {
          limit           = 3
          grace           = "60s"
          ignore_warnings = false
        }
      }

      check {
        name     = "http-ready"
        type     = "http"
        path     = "/ready"
        interval = "15s"
        timeout  = "5s"
      }

      # -- Consul Connect service mesh --
      connect {
        sidecar_service {
          proxy {
            local_service_port = 8080

            upstreams {
              destination_name = "postgres"
              local_bind_port  = 5432
            }

            upstreams {
              destination_name = "redis"
              local_bind_port  = 6379
            }
          }
        }
      }
    }

    # -- Metrics service (separate from main service) --
    service {
      name     = "web-service-metrics"
      port     = "metrics"
      provider = "consul"
      tags     = ["metrics", "prometheus"]

      check {
        type     = "http"
        path     = "/metrics"
        interval = "30s"
        timeout  = "5s"
      }
    }

    # -- Ephemeral disk for temp files --
    ephemeral_disk {
      size    = 500     # MB
      migrate = true
      sticky  = true
    }

    # -- Main application task --
    task "app" {
      driver = "docker"

      config {
        image = var.image
        ports = ["http", "metrics"]

        # Security hardening
        readonly_rootfs = true
        cap_drop        = ["ALL"]
        cap_add         = ["NET_BIND_SERVICE"]
        security_opt    = ["no-new-privileges"]
        pids_limit      = 200

        volumes = [
          "local/config:/app/config:ro",
          "secrets:/app/secrets:ro",
        ]

        logging {
          type = "json-file"
          config {
            max-size = "10m"
            max-file = "3"
          }
        }
      }

      # Run as non-root
      user = "1000:1000"

      # -- Vault secrets --
      vault {
        policies    = ["web-service-read"]
        change_mode = "restart"
      }

      # Render database credentials from Vault
      template {
        data = <<-EOF
          {{ with secret "database/creds/web-service" }}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{ end }}
          {{ with secret "secret/data/web-service/config" }}
          API_KEY={{ .Data.data.api_key }}
          JWT_SECRET={{ .Data.data.jwt_secret }}
          {{ end }}
        EOF
        destination = "secrets/vault.env"
        env         = true
        change_mode = "restart"
      }

      # Render app config from Nomad Variables
      template {
        data = <<-EOF
          {{ with nomadVar "nomad/jobs/web-service/config" }}
          LOG_LEVEL={{ .log_level }}
          FEATURE_FLAGS={{ .feature_flags }}
          {{ end }}
          NOMAD_ALLOC_ID={{ env "NOMAD_ALLOC_ID" }}
          NOMAD_DC={{ env "NOMAD_DC" }}
        EOF
        destination = "local/config/app.env"
        env         = true
        change_mode = "noop"
      }

      # Wait for upstream services
      template {
        data = <<-EOF
          {{ range service "postgres" }}{{ end }}
          DEPS_READY=true
        EOF
        destination = "local/deps.txt"
        wait {
          min = "2s"
          max = "30s"
        }
      }

      resources {
        cpu        = 500      # MHz
        memory     = 256      # MB (guaranteed)
        memory_max = 512      # MB (burst limit)
      }
    }

    # -- Log shipping sidecar --
    task "log-shipper" {
      driver = "docker"
      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      config {
        image = "timberio/vector:0.38.0-alpine"
        args  = ["--config", "/etc/vector/vector.toml"]
      }

      template {
        data = <<-EOF
          [sources.logs]
          type = "file"
          include = ["/alloc/logs/app.*"]

          [sinks.output]
          type = "console"
          inputs = ["logs"]
          encoding.codec = "json"
        EOF
        destination = "local/vector.toml"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
