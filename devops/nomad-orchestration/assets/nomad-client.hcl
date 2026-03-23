# Production Nomad Client Configuration
#
# Deploy on every workload node. Clients execute task drivers and
# report status to servers.
#
# File: /etc/nomad.d/nomad.hcl (or /etc/nomad.d/client.hcl)
# Usage: nomad agent -config=/etc/nomad.d/

# ── General ──

data_dir   = "/opt/nomad/data"
bind_addr  = "0.0.0.0"
datacenter = "dc1"
region     = "us-east-1"
log_level  = "INFO"
log_json   = true
log_file   = "/var/log/nomad/nomad.log"
log_rotate_bytes    = 104857600
log_rotate_duration = "24h"
log_rotate_max_files = 7

advertise {
  http = "{{ GetPrivateIP }}:4646"
  rpc  = "{{ GetPrivateIP }}:4647"
}

# ── Client ──

client {
  enabled = true

  # Server discovery via Consul (preferred) or explicit addresses
  server_join {
    retry_join     = ["provider=aws tag_key=NomadRole tag_value=server"]
    retry_max      = 10
    retry_interval = "15s"
  }

  # Node metadata — used for constraints/affinities in job specs
  meta {
    "node_class"   = "general"       # or "gpu", "high-memory", "edge"
    "storage_type" = "ssd"           # used by affinity blocks
    "rack"         = "rack-01"       # for spread scheduling
    "az"           = "us-east-1a"    # availability zone
  }

  # Node class — broad scheduling category
  node_class = "general"

  # Network interface for fingerprinting
  network_interface = "eth0"

  # CNI plugin path for bridge networking
  cni_path         = "/opt/cni/bin"
  cni_config_dir   = "/opt/cni/config"

  # Dynamic port allocation range
  min_dynamic_port = 20000
  max_dynamic_port = 32000

  # Reserve resources for the OS, Nomad agent, and system services
  reserved {
    cpu            = 500       # MHz reserved for system
    memory         = 512       # MB reserved for system
    disk           = 1024      # MB reserved for system
    reserved_ports = "22,8500-8502"  # SSH + Consul ports
  }

  # Garbage collection
  gc_interval             = "1m"
  gc_disk_usage_threshold = 80       # trigger GC at 80% disk usage
  gc_inode_usage_threshold = 70
  gc_max_allocs           = 50       # max dead allocs to retain
  gc_parallel_destroys    = 2

  # Chroot environment for exec/java drivers
  chroot_env {
    "/bin"           = "/bin"
    "/etc"           = "/etc"
    "/lib"           = "/lib"
    "/lib32"         = "/lib32"
    "/lib64"         = "/lib64"
    "/run/resolvconf" = "/run/resolvconf"
    "/sbin"          = "/sbin"
    "/usr"           = "/usr"
  }

  # Bridge network subnet (for bridge mode allocations)
  bridge_network_subnet = "172.26.64.0/20"
}

# ── Host Volumes ──
# Define volumes that tasks can mount. Directories must exist on the host.

host_volume "mysql-data" {
  path      = "/opt/nomad/volumes/mysql"
  read_only = false
}

host_volume "app-data" {
  path      = "/opt/nomad/volumes/app-data"
  read_only = false
}

host_volume "certs" {
  path      = "/opt/nomad/volumes/certs"
  read_only = true
}

# Shared volume for allocation logs (used by log collector system jobs)
host_volume "nomad-alloc-logs" {
  path      = "/opt/nomad/data/alloc"
  read_only = true
}

host_volume "syslog" {
  path      = "/var/log"
  read_only = true
}

# ── Docker Driver ──

plugin "docker" {
  config {
    # Docker socket
    endpoint = "unix:///var/run/docker.sock"

    # Security: disallow privileged containers by default
    allow_privileged = false

    # Volume mounting
    volumes {
      enabled      = true
      selinuxlabel = "z"
    }

    # Image garbage collection
    gc {
      image       = true
      image_delay = "3m"
      container   = true

      dangling_containers {
        enabled        = true
        dry_run        = false
        period         = "5m"
        creation_grace = "5m"
      }
    }

    # Extra labels on containers for identification
    extra_labels = ["job_name", "task_group_name", "task_name", "node_name"]

    # Pull timeout
    pull_activity_timeout = "10m"

    # Logging defaults
    logging {
      type = "json-file"
      config {
        max-size = "10m"
        max-file = "3"
      }
    }

    # Private registry authentication (optional)
    # auth {
    #   config = "/root/.docker/config.json"
    # }

    # Infra image for bridge networking
    infra_image = "gcr.io/google_containers/pause-amd64:3.3"
  }
}

# ── Exec Driver ──

plugin "exec" {
  config {
    # Inherits chroot_env from client block
  }
}

# ── Raw Exec Driver (disabled by default — enable only if required) ──

plugin "raw_exec" {
  config {
    enabled = false    # SECURITY: no isolation — avoid in production
  }
}

# ── TLS ──

tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/client.pem"
  key_file  = "/etc/nomad.d/tls/client-key.pem"

  verify_server_hostname = true
}

# ── ACL ──

acl {
  enabled = true
}

# ── Consul Integration ──

consul {
  address             = "127.0.0.1:8501"
  ssl                 = true
  ca_file             = "/etc/nomad.d/tls/consul-ca.pem"
  cert_file           = "/etc/nomad.d/tls/consul-client.pem"
  key_file            = "/etc/nomad.d/tls/consul-client-key.pem"
  client_service_name = "nomad-client"
  auto_advertise      = true
  token               = "REPLACE_WITH_CONSUL_TOKEN"

  # gRPC port for Consul Connect (Envoy proxy management)
  grpc_address = "127.0.0.1:8502"
}

# ── Vault Integration ──

vault {
  enabled = true
  address = "https://vault.service.consul:8200"

  ca_path         = "/etc/nomad.d/tls/vault-ca.pem"
  tls_skip_verify = false
}

# ── Telemetry ──

telemetry {
  collection_interval        = "10s"
  disable_hostname           = false
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
  prometheus_retention_time  = "24h"
}

# ── NVIDIA GPU Plugin (uncomment on GPU nodes) ──

# plugin "nvidia-gpu" {
#   config {
#     enabled            = true
#     fingerprint_period = "1m"
#   }
# }
