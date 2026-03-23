# Production Nomad Server Configuration
#
# Deploy on 3 or 5 dedicated server nodes (always odd count).
# Never co-locate server and client roles in production.
#
# File: /etc/nomad.d/nomad.hcl (or /etc/nomad.d/server.hcl)
# Usage: nomad agent -config=/etc/nomad.d/

# ── General ──

data_dir   = "/opt/nomad/data"
bind_addr  = "0.0.0.0"
datacenter = "dc1"
region     = "us-east-1"
log_level  = "INFO"
log_json   = true
log_file   = "/var/log/nomad/nomad.log"
log_rotate_bytes    = 104857600    # 100 MB
log_rotate_duration = "24h"
log_rotate_max_files = 14

# Advertise the private IP (replace with actual IP or use Go template)
advertise {
  http = "{{ GetPrivateIP }}:4646"
  rpc  = "{{ GetPrivateIP }}:4647"
  serf = "{{ GetPrivateIP }}:4648"
}

# ── Server ──

server {
  enabled          = true
  bootstrap_expect = 3
  encrypt          = "REPLACE_WITH_GOSSIP_KEY"    # nomad operator gossip keyring generate

  # Auto-join via cloud provider tags (AWS example)
  server_join {
    retry_join     = ["provider=aws tag_key=NomadRole tag_value=server"]
    retry_max      = 10
    retry_interval = "15s"
  }

  # Raft protocol version
  raft_protocol = 3

  # Raft performance tuning — adjust for network latency
  raft_multiplier = 1    # 1 = tight timeouts (fast failover), increase for high-latency

  # Autopilot — automatic server management
  autopilot {
    cleanup_dead_servers      = true
    last_contact_threshold    = "200ms"
    max_trailing_logs         = 250
    min_quorum                = 3
    server_stabilization_time = "10s"
  }

  # Garbage collection
  job_gc_interval   = "5m"
  job_gc_threshold  = "4h"
  eval_gc_threshold = "1h"
  node_gc_threshold = "24h"

  # Search (disable in large clusters for performance)
  search {
    fuzzy_enabled   = true
    min_term_length = 3
  }

  # Multi-region federation (uncomment and set for multi-region)
  # authoritative_region = "us-east-1"
}

# ── ACL ──

acl {
  enabled = true
}

# ── TLS ──

tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/tls/ca.pem"
  cert_file = "/etc/nomad.d/tls/server.pem"
  key_file  = "/etc/nomad.d/tls/server-key.pem"

  verify_server_hostname = true     # prevent server impersonation
  verify_https_client    = true     # require client certificates for API
}

# ── Consul Integration ──

consul {
  address             = "127.0.0.1:8501"     # HTTPS Consul port
  ssl                 = true
  ca_file             = "/etc/nomad.d/tls/consul-ca.pem"
  cert_file           = "/etc/nomad.d/tls/consul-client.pem"
  key_file            = "/etc/nomad.d/tls/consul-client-key.pem"
  server_service_name = "nomad"
  server_auto_join    = true
  auto_advertise      = true
  token               = "REPLACE_WITH_CONSUL_TOKEN"
}

# ── Vault Integration ──

vault {
  enabled = true
  address = "https://vault.service.consul:8200"

  ca_path         = "/etc/nomad.d/tls/vault-ca.pem"
  tls_skip_verify = false

  # Workload Identity (v1.7+) — preferred over long-lived tokens
  default_identity {
    aud  = ["vault.io"]
    ttl  = "1h"
    env  = false
    file = false
  }

  # Legacy token-based auth (use if not on Workload Identity)
  # token            = "REPLACE_WITH_VAULT_TOKEN"
  # create_from_role = "nomad-cluster"
}

# ── Telemetry ──

telemetry {
  collection_interval        = "10s"
  disable_hostname           = false
  publish_allocation_metrics = true
  publish_node_metrics       = true

  # Prometheus
  prometheus_metrics        = true
  prometheus_retention_time = "24h"

  # StatsD (optional — for Datadog, Graphite, etc.)
  # statsd_address = "127.0.0.1:8125"

  # DogStatsD (optional — for Datadog)
  # datadog_address = "127.0.0.1:8125"
  # datadog_tags    = ["region:us-east-1", "env:production"]
}

# ── Audit Logging (Enterprise) ──

# audit {
#   enabled = true
#   sink "file" {
#     type               = "file"
#     delivery_guarantee = "enforced"
#     format             = "json"
#     path               = "/var/log/nomad/audit.json"
#     rotate_bytes       = 104857600
#     rotate_duration    = "24h"
#     rotate_max_files   = 30
#   }
# }

# ── Sentinel (Enterprise) ──

# sentinel {
#   import "http" {
#     args = []
#   }
# }

# ── Limits ──

limits {
  https_handshake_timeout   = "5s"
  http_max_conns_per_client = 200
  rpc_handshake_timeout     = "5s"
}
