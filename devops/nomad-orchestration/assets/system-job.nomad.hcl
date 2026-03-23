# System Job — Nomad Job Template
#
# Runs one instance per client node. Ideal for node-level agents:
# log collectors, monitoring exporters, security agents, DNS forwarders.
#
# Usage: nomad job run system-job.nomad.hcl

variable "log_collector_image" {
  description = "Docker image for the log collector"
  type        = string
  default     = "timberio/vector:0.38.0-alpine"
}

variable "node_exporter_image" {
  description = "Docker image for Prometheus node exporter"
  type        = string
  default     = "prom/node-exporter:v1.8.2"
}

# ────────────────────────────────────────────
# Example 1: Log Collector (Vector/Fluentd)
# ────────────────────────────────────────────

job "log-collector" {
  datacenters = ["dc1", "dc2"]
  type        = "system"
  namespace   = "platform"
  priority    = 80      # high priority — observability is critical

  # System jobs use a simplified update strategy
  update {
    max_parallel = 1
    stagger      = "30s"
  }

  group "collector" {
    # Constraint: only Linux nodes
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "linux"
    }

    network {
      mode = "host"

      port "api" {
        static = 8686
        to     = 8686
      }
    }

    # Register with Consul for monitoring
    service {
      name     = "log-collector"
      port     = "api"
      provider = "consul"
      tags     = ["system", "logging"]

      check {
        type     = "http"
        path     = "/health"
        interval = "15s"
        timeout  = "5s"
      }
    }

    # Mount host log directories
    volume "alloc-logs" {
      type      = "host"
      source    = "nomad-alloc-logs"
      read_only = true
    }

    volume "syslog" {
      type      = "host"
      source    = "syslog"
      read_only = true
    }

    task "vector" {
      driver = "docker"

      config {
        image        = var.log_collector_image
        args         = ["--config", "/etc/vector/vector.toml"]
        ports        = ["api"]
        network_mode = "host"     # access host network for log forwarding

        # Need to read host logs
        volumes = [
          "/var/log:/var/log:ro",
        ]
      }

      volume_mount {
        volume      = "alloc-logs"
        destination = "/nomad/alloc-logs"
        read_only   = true
      }

      volume_mount {
        volume      = "syslog"
        destination = "/host/syslog"
        read_only   = true
      }

      # Vector configuration
      template {
        data = <<-EOF
          [api]
          enabled = true
          address = "0.0.0.0:8686"

          [sources.nomad_logs]
          type = "file"
          include = ["/nomad/alloc-logs/*/alloc/logs/*.stdout.*", "/nomad/alloc-logs/*/alloc/logs/*.stderr.*"]
          read_from = "beginning"

          [sources.syslog]
          type = "file"
          include = ["/host/syslog/syslog", "/host/syslog/auth.log"]

          [transforms.parse]
          type = "remap"
          inputs = ["nomad_logs"]
          source = '''
            .host = get_hostname!()
            .datacenter = "{{ env "NOMAD_DC" }}"
            .node_id = "{{ env "NOMAD_NODE_ID" }}"
          '''

          [sinks.loki]
          type = "loki"
          inputs = ["parse", "syslog"]
          endpoint = "http://loki.service.consul:3100"
          encoding.codec = "json"
          labels.host = "{{ "{{" }} host {{ "}}" }}"
          labels.datacenter = "{{ "{{" }} datacenter {{ "}}" }}"
        EOF
        destination = "local/vector.toml"
        change_mode = "signal"
        change_signal = "SIGHUP"
      }

      resources {
        cpu    = 200
        memory = 128
      }
    }
  }
}

# ──────────────────────────────────────────────
# Example 2: Monitoring Agent (Node Exporter)
# ──────────────────────────────────────────────

job "node-exporter" {
  datacenters = ["dc1", "dc2"]
  type        = "system"
  namespace   = "platform"
  priority    = 80

  update {
    max_parallel = 1
    stagger      = "15s"
  }

  group "exporter" {
    constraint {
      attribute = "${attr.kernel.name}"
      value     = "linux"
    }

    network {
      mode = "host"

      port "metrics" {
        static = 9100
        to     = 9100
      }
    }

    service {
      name     = "node-exporter"
      port     = "metrics"
      provider = "consul"
      tags     = ["system", "metrics", "prometheus"]

      check {
        type     = "http"
        path     = "/metrics"
        interval = "30s"
        timeout  = "5s"
      }

      meta {
        metrics_path = "/metrics"
      }
    }

    task "node-exporter" {
      driver = "docker"

      config {
        image        = var.node_exporter_image
        ports        = ["metrics"]
        network_mode = "host"
        pid_mode     = "host"      # required for process metrics

        args = [
          "--path.procfs=/host/proc",
          "--path.sysfs=/host/sys",
          "--path.rootfs=/host/root",
          "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)",
        ]

        volumes = [
          "/proc:/host/proc:ro",
          "/sys:/host/sys:ro",
          "/:/host/root:ro",
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
