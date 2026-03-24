# NATS Operations Guide

Production deployment, management, and maintenance procedures for NATS infrastructure.

## Table of Contents

- [1. Cluster Sizing and Topology](#1-cluster-sizing-and-topology)
- [2. TLS Configuration](#2-tls-configuration)
- [3. OCSP Stapling](#3-ocsp-stapling)
- [4. Account Management with nsc](#4-account-management-with-nsc)
- [5. Resolver Configuration](#5-resolver-configuration)
- [6. Backup and Restore](#6-backup-and-restore)
- [7. Rolling Upgrades](#7-rolling-upgrades)
- [8. Resource Limits](#8-resource-limits)
- [9. Logging Configuration](#9-logging-configuration)
- [10. Monitoring with Prometheus and Grafana](#10-monitoring-with-prometheus-and-grafana)
- [11. Capacity Planning](#11-capacity-planning)
- [12. Disaster Recovery](#12-disaster-recovery)

---

## 1. Cluster Sizing and Topology

### Node Count Guidelines

| Cluster Size | Fault Tolerance | Use Case |
|-------------|----------------|----------|
| 1 node | None | Development, testing |
| 3 nodes | 1 node failure | Standard production |
| 5 nodes | 2 node failures | High-availability critical systems |

**Never run 2 or 4 nodes** — even node counts create split-brain risk with Raft consensus.

### Hardware Recommendations

| Component | Small (<10K msg/s) | Medium (10K–100K msg/s) | Large (>100K msg/s) |
|-----------|-------------------|------------------------|---------------------|
| CPU | 2 cores | 4–8 cores | 8–16 cores |
| RAM | 2 GB | 8–16 GB | 32–64 GB |
| Disk | SSD, 50 GB | NVMe SSD, 200 GB | NVMe SSD, 1+ TB |
| Network | 1 Gbps | 10 Gbps | 10–25 Gbps |

**Key sizing factors:**
- **Memory**: Core NATS uses ~1 KB per connection + subscription tracking. JetStream memory stores consume configured `max_mem`.
- **Disk**: JetStream file stores. Size = (msg_rate × avg_msg_size × retention_period × replicas).
- **CPU**: Mostly I/O-bound. CPU spikes during TLS handshakes, compression, and stream compaction.
- **Network**: Each message replicated R times in a cluster. Effective bandwidth = throughput × R.

### Network Topology

```
                    ┌─── Gateway ───┐
                    │               │
    ┌───────────────┴──┐        ┌──┴───────────────┐
    │   DC-EAST        │        │   DC-WEST        │
    │  ┌────┐ ┌────┐   │        │  ┌────┐ ┌────┐   │
    │  │ n1 │─│ n2 │   │        │  │ n4 │─│ n5 │   │
    │  └──┬─┘ └──┬─┘   │        │  └──┬─┘ └──┬─┘   │
    │     │   ┌──┴─┐   │        │     │   ┌──┴─┐   │
    │     └───│ n3 │   │        │     └───│ n6 │   │
    │         └────┘   │        │         └────┘   │
    └──────────────────┘        └──────────────────┘
              │                           │
         ┌────┴────┐                 ┌────┴────┐
         │ Leaf    │                 │ Leaf    │
         │ (Edge)  │                 │ (Edge)  │
         └─────────┘                 └─────────┘
```

- **Cluster routes**: port 6222, within a datacenter
- **Gateways**: port 7222, between datacenters (interest-only propagation)
- **Leaf nodes**: port 7422, edge/IoT/remote locations

### Placement Rules

- Place cluster nodes across **failure domains** (different racks, availability zones).
- Use **dedicated disks** for JetStream storage (avoid sharing with OS or other workloads).
- Place client-facing load balancers **in front of client ports only** (not cluster/gateway ports).
- Cluster routes should be on a **low-latency, high-bandwidth** network (ideally <2ms RTT).

---

## 2. TLS Configuration

### Full TLS Setup

```hcl
# nats-server.conf — Client TLS
tls {
    cert_file:  "/etc/nats/certs/server-cert.pem"
    key_file:   "/etc/nats/certs/server-key.pem"
    ca_file:    "/etc/nats/certs/ca-cert.pem"

    # Mutual TLS: require client certificates
    verify: true

    # Minimum TLS version
    min_version: "1.2"
    # Prefer server cipher suites
    # cipher_suites: [
    #     "TLS_AES_256_GCM_SHA384",
    #     "TLS_CHACHA20_POLY1305_SHA256",
    #     "TLS_AES_128_GCM_SHA256"
    # ]

    # Timeout for TLS handshake
    timeout: 5
}

# Cluster TLS (separate certs recommended)
cluster {
    name: "production"
    listen: "0.0.0.0:6222"
    tls {
        cert_file:  "/etc/nats/certs/cluster-cert.pem"
        key_file:   "/etc/nats/certs/cluster-key.pem"
        ca_file:    "/etc/nats/certs/ca-cert.pem"
        verify: true
    }
    routes: [
        "nats-route://n1.example.com:6222"
        "nats-route://n2.example.com:6222"
        "nats-route://n3.example.com:6222"
    ]
}

# Gateway TLS
gateway {
    name: "dc-east"
    listen: "0.0.0.0:7222"
    tls {
        cert_file: "/etc/nats/certs/gateway-cert.pem"
        key_file:  "/etc/nats/certs/gateway-key.pem"
        ca_file:   "/etc/nats/certs/ca-cert.pem"
        verify: true
    }
}

# Leaf node TLS
leafnodes {
    listen: "0.0.0.0:7422"
    tls {
        cert_file: "/etc/nats/certs/leaf-cert.pem"
        key_file:  "/etc/nats/certs/leaf-key.pem"
        ca_file:   "/etc/nats/certs/ca-cert.pem"
        verify: true
    }
}
```

### Certificate Generation with OpenSSL

```bash
# Generate CA
openssl genrsa -out ca-key.pem 4096
openssl req -x509 -new -key ca-key.pem -sha256 -days 3650 \
  -out ca-cert.pem -subj "/CN=NATS CA"

# Generate server cert with SANs
openssl genrsa -out server-key.pem 2048
cat > server-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = nats-server

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = nats-1.example.com
DNS.2 = nats-2.example.com
DNS.3 = nats-3.example.com
DNS.4 = *.nats.svc.cluster.local
IP.1 = 10.0.1.10
IP.2 = 10.0.1.11
IP.3 = 10.0.1.12
EOF

openssl req -new -key server-key.pem -out server.csr -config server-csr.conf
openssl x509 -req -in server.csr -CA ca-cert.pem -CAkey ca-key.pem \
  -CAcreateserial -out server-cert.pem -days 365 \
  -extfile server-csr.conf -extensions v3_req

# Verify
openssl verify -CAfile ca-cert.pem server-cert.pem
openssl x509 -in server-cert.pem -noout -text | grep -A2 "Subject Alternative Name"
```

### Certificate Rotation

1. Generate new certificates with overlapping validity periods
2. Update cert files on disk (or Kubernetes secrets)
3. Send `SIGHUP` to NATS server — it reloads TLS config without dropping connections
4. Verify: `openssl s_client -connect nats:4222 </dev/null 2>&1 | openssl x509 -noout -dates`

```bash
# Hot reload (no downtime)
kill -HUP $(pidof nats-server)

# Verify new cert is active
openssl s_client -connect localhost:4222 -servername nats.example.com </dev/null 2>&1 \
  | openssl x509 -noout -serial -dates
```

---

## 3. OCSP Stapling

OCSP stapling lets the NATS server present a signed OCSP response during TLS handshake, so clients don't need to contact the CA's OCSP responder.

```hcl
# Enable OCSP stapling
ocsp {
    mode: always        # always | never | must_staple
    url: ""             # Override OCSP responder URL (auto-detected from cert by default)
}

tls {
    cert_file: "/etc/nats/certs/server-cert.pem"
    key_file:  "/etc/nats/certs/server-key.pem"
    ca_file:   "/etc/nats/certs/ca-cert.pem"
}
```

**Modes:**
- `always`: Server fetches and staples OCSP response. Startup fails if OCSP responder unreachable.
- `never`: Disable OCSP stapling.
- `must_staple`: Like `always`, but also requires the certificate to have the OCSP Must-Staple extension.

**Monitoring OCSP status:**

```bash
# Check OCSP staple manually
openssl s_client -connect nats:4222 -status </dev/null 2>&1 | grep -A5 "OCSP Response"

# Via NATS monitoring
curl -s http://localhost:8222/varz | jq '.tls_ocsp_peer_cache'
```

---

## 4. Account Management with nsc

`nsc` is the CLI for managing operators, accounts, and users in NATS JWT-based auth.

### Initial Setup

```bash
# Install nsc
curl -fsSL https://raw.githubusercontent.com/nats-io/nsc/main/install.sh | bash

# Create operator with system account
nsc add operator --generate-signing-key --sys --name prod-operator

# Set operator defaults
nsc edit operator --require-signing-keys \
  --account-jwt-server-url "nats://nats-1.example.com:4222"

# Create accounts
nsc add account --name orders-svc
nsc add account --name billing-svc
nsc add account --name monitoring

# Set account limits
nsc edit account --name orders-svc \
  --conns 500 \
  --data -1 \
  --exports -1 \
  --imports -1 \
  --js-mem-storage 1G \
  --js-disk-storage 50G \
  --js-streams 50 \
  --js-consumer 200 \
  --payload 1048576

# Create users within accounts
nsc add user --account orders-svc --name order-writer \
  --allow-pub "orders.>" \
  --allow-sub "orders.>,_INBOX.>"

nsc add user --account orders-svc --name order-reader \
  --deny-pub ">" \
  --allow-sub "orders.>"

# Generate credentials file for a user
nsc generate creds --account orders-svc --name order-writer \
  -o /etc/nats/creds/order-writer.creds
```

### Signing Keys (Recommended for Production)

```bash
# Add signing key to account (the operator signing key signs the account JWT)
nsc edit account --name orders-svc --sk generate

# Users created after this are signed by the account's signing key
# The operator's private key can be stored offline (cold storage)
nsc add user --account orders-svc --name new-user

# List signing keys
nsc describe account --name orders-svc --json | jq '.nats.signing_keys'
```

### Revoking Users

```bash
# Revoke a specific user
nsc revocations add-user --account orders-svc --name compromised-user

# Revoke all users issued before a time (rotation)
nsc revocations add-user --account orders-svc --before "2024-01-15"

# Push revocation to live server
nsc push --account orders-svc
```

---

## 5. Resolver Configuration

The resolver tells the NATS server how to find account JWTs.

### Full NATS Resolver (Recommended)

Account JWTs stored in the NATS cluster itself (replicated via JetStream).

```bash
# Generate resolver config
nsc generate config --nats-resolver --sys-account SYS > /etc/nats/resolver.conf
```

```hcl
# Include in nats-server.conf
include /etc/nats/resolver.conf

# The generated file contains:
# operator: <operator JWT>
# system_account: <SYS account public key>
# resolver: {
#     type: full
#     dir: "/data/nats/jwt"
#     allow_delete: false
#     interval: "2m"        # Sync interval
#     limit: 1000           # Max accounts
# }
# resolver_preload: {
#     <account_pubkey>: <account_jwt>
# }
```

### Memory Resolver (Small Deployments)

All account JWTs preloaded in config:

```hcl
resolver: MEMORY
resolver_preload: {
    ACSN...: "eyJ..."   # orders-svc JWT
    ABCD...: "eyJ..."   # billing-svc JWT
}
```

### URL Resolver (External JWT Server)

```hcl
resolver: URL("http://nats-account-server:9090/jwt/v1/accounts/")
```

### Pushing Account Updates

```bash
# Push all accounts
nsc push -A

# Push specific account
nsc push --account orders-svc

# Verify account is resolved on server
nsc pull --account orders-svc
nsc describe account --name orders-svc
```

---

## 6. Backup and Restore

### JetStream Data Backup

```bash
# Method 1: nats CLI stream backup (recommended)
# Creates a portable backup of stream messages
nats stream backup ORDERS /backup/orders-$(date +%Y%m%d).tar.gz
nats stream backup PAYMENTS /backup/payments-$(date +%Y%m%d).tar.gz

# Backup all streams
for stream in $(nats stream ls -n); do
    echo "Backing up $stream..."
    nats stream backup "$stream" "/backup/${stream}-$(date +%Y%m%d).tar.gz"
done

# Method 2: File-system backup (requires stopping writes or snapshotting)
# Stop JetStream on the node first, or use LVM/ZFS snapshots
rsync -avz /data/nats/jetstream/ /backup/js-snapshot/
```

### Restore

```bash
# Restore a stream from backup
nats stream restore ORDERS /backup/orders-20240115.tar.gz

# Restore with different config (e.g., fewer replicas for dev)
nats stream restore ORDERS /backup/orders-20240115.tar.gz \
  --config '{"replicas": 1, "storage": "file"}'
```

### KV and Object Store Backup

```bash
# KV stores are JetStream streams under the hood (KV_<bucket>)
nats stream backup KV_CONFIG /backup/kv-config.tar.gz

# Object stores similarly (OBJ_<bucket>)
nats stream backup OBJ_ARTIFACTS /backup/obj-artifacts.tar.gz
```

### Account/JWT Backup

```bash
# Backup nsc data directory
tar czf /backup/nsc-data-$(date +%Y%m%d).tar.gz ~/.local/share/nats/nsc/

# Backup operator and account JWTs
nsc describe operator --json > /backup/operator.json
for acct in $(nsc list accounts -R -n); do
    nsc describe account --name "$acct" --json > "/backup/account-${acct}.json"
done
```

### Automated Backup Script

```bash
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/backup/nats/$(date +%Y%m%d-%H%M)"
RETENTION_DAYS=30
SERVER="nats://localhost:4222"

mkdir -p "$BACKUP_DIR"

# Backup all streams
for stream in $(nats stream ls -n --server "$SERVER"); do
    nats stream backup "$stream" "${BACKUP_DIR}/${stream}.tar.gz" --server "$SERVER"
    echo "✓ Backed up stream: $stream"
done

# Cleanup old backups
find /backup/nats/ -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} +

echo "Backup complete: $BACKUP_DIR"
```

---

## 7. Rolling Upgrades

### Upgrade Procedure (Zero Downtime)

**Pre-upgrade checks:**

```bash
# 1. Verify current cluster state
nats server report jetstream
nats server ls

# 2. Check binary version compatibility
nats-server --version
# New binary:
/tmp/nats-server-new --version

# 3. Ensure all streams are healthy (all replicas current)
for stream in $(nats stream ls -n); do
    nats stream info "$stream" --json | jq '{name: .config.name, replicas: .cluster.replicas}'
done
```

**Upgrade one node at a time:**

```bash
# 1. Drain connections from the node (graceful migration)
nats server request lame-duck-mode --server nats://node-to-upgrade:4222

# 2. Wait for connections to drain (monitor via /connz)
watch -n 2 'curl -s http://node-to-upgrade:8222/connz | jq .num_connections'

# 3. Stop the old server
systemctl stop nats-server
# Or: kill -SIGTERM $(pidof nats-server)

# 4. Replace binary
cp /tmp/nats-server-new /usr/local/bin/nats-server

# 5. Start new version
systemctl start nats-server

# 6. Verify the node rejoined and streams are replicating
nats server report jetstream
nats server ping

# 7. Wait for all streams to fully catch up before proceeding to next node
for stream in $(nats stream ls -n); do
    echo -n "$stream: "
    nats stream info "$stream" --json | \
        jq '.cluster.replicas[] | select(.lag > 0) | {name, lag}'
done

# 8. Repeat for next node
```

### Lame Duck Mode

Lame duck mode gracefully drains a server:
1. Server stops accepting new connections
2. Existing connections receive a lame-duck notification
3. Clients reconnect to other cluster nodes
4. After timeout, remaining connections are closed
5. Server shuts down

```hcl
# Server config — set lame duck duration
lame_duck_duration: "30s"       # Default: 2 minutes
lame_duck_grace_period: "10s"   # Grace before starting drain
```

```bash
# Trigger lame duck via signal
kill -SIGINT $(pidof nats-server)
# Or via nats CLI
nats server request lame-duck-mode
```

---

## 8. Resource Limits

### Server-Level Limits

```hcl
# nats-server.conf
max_connections: 65536        # Total client connections
max_payload: 8MB              # Max message size (default 1MB)
max_pending: 67108864         # 64MB write buffer per client
max_control_line: 4KB         # Max protocol control line
max_subscriptions: 0          # 0 = unlimited
write_deadline: "10s"         # Max time to write to slow client

ping_interval: 20             # Seconds between keepalive pings
ping_max: 3                   # Missed pongs before disconnect

# JetStream limits
jetstream {
    max_mem: 4GB              # Total memory for memory-backed streams
    max_file: 100GB           # Total disk for file-backed streams
    store_dir: "/data/nats/jetstream"
}
```

### Account-Level Limits (with nsc)

```bash
nsc edit account --name my-account \
  --conns 1000 \               # Max connections
  --leaf-conns 50 \            # Max leaf node connections
  --data -1 \                  # Max data in bytes (-1 = unlimited)
  --exports 100 \              # Max exports
  --imports 100 \              # Max imports
  --payload 1048576 \          # Max message payload (1MB)
  --subscriptions 10000 \     # Max subscriptions
  --js-mem-storage 2G \        # JetStream memory limit
  --js-disk-storage 100G \     # JetStream disk limit
  --js-streams 100 \           # Max streams
  --js-consumer 500            # Max consumers
```

### Per-User Limits

```hcl
# Static config
authorization {
    users: [
        {
            user: "limited-user"
            password: "$2a$..."
            permissions {
                publish: { allow: ["app.>"] }
                subscribe: { allow: ["app.>"], max: 100 }  # Max 100 subscriptions
            }
            # Connection limits
            max_payload: 524288   # 512KB for this user
        }
    ]
}
```

### Monitoring Limit Usage

```bash
# Server-wide
curl -s http://localhost:8222/varz | jq '{
    connections: .connections,
    max_connections: .max_connections,
    mem: .mem,
    slow_consumers: .slow_consumers
}'

# Per-account
curl -s 'http://localhost:8222/accountz?acc=ORDERS_SVC' | jq '{
    connections: .num_connections,
    conn_limit: .limits.max_connections,
    js_memory: .jetstream_stats.memory,
    js_storage: .jetstream_stats.store
}'

# JetStream usage
curl -s http://localhost:8222/jsz | jq '{
    memory_used: .memory,
    memory_reserved: .reserved_memory,
    store_used: .store,
    store_reserved: .reserved_store
}'
```

---

## 9. Logging Configuration

### Server Logging Options

```hcl
# Output destination
log_file: "/var/log/nats/nats-server.log"   # File (omit for stdout)
log_size_limit: 100MB                        # Rotate at this size
# max_traced_msg_len: 1024                   # Truncate traced messages

# Verbosity levels (cumulative)
debug: false          # Protocol-level debug info
trace: false          # Full message tracing (very verbose — dev only)
trace_verbose: false  # Even more trace detail
logtime: true         # Timestamps in log lines
log_file_max_num: 5   # Keep N rotated log files

# Syslog integration (alternative to file)
# syslog {
#     host: "syslog.example.com:514"
#     proto: "udp"
#     name: "nats-prod-1"
# }
```

### Log Levels in Practice

| Setting | Use Case | Impact |
|---------|----------|--------|
| `logtime: true` only | Production baseline | Minimal overhead |
| `debug: true` | Connection troubleshooting | ~5% CPU increase |
| `trace: true` | Message routing investigation | ~20%+ CPU increase, **never in production** |

### Structured Logging with Log Aggregation

```bash
# JSON log format (pipe through jq for structured parsing)
nats-server -c nats.conf 2>&1 | \
  sed 's/\[/{"level":"/; s/\] /","msg":"/; s/$/"}/' >> /var/log/nats/structured.json

# Better: use fluentd/filebeat sidecar to ship logs
# Filebeat config for NATS logs
# filebeat.yml:
#   - type: log
#     paths: ["/var/log/nats/*.log"]
#     fields:
#       service: nats
#       environment: production
```

### Runtime Log Level Change

```bash
# Enable debug logging without restart (via config reload)
# 1. Edit nats-server.conf: set debug: true
# 2. Signal reload:
kill -HUP $(pidof nats-server)
# Logs: [INF] Reloaded server configuration

# Disable after investigation:
# 1. Set debug: false
# 2. kill -HUP again
```

---

## 10. Monitoring with Prometheus and Grafana

### Prometheus NATS Exporter

```bash
# Install
go install github.com/nats-io/prometheus-nats-exporter@latest

# Run (exposes metrics on :7777/metrics)
prometheus-nats-exporter \
  -varz -connz -routez -subsz -jsz -leafz -gatewayz \
  -port 7777 \
  -addr 0.0.0.0 \
  http://nats-1:8222 http://nats-2:8222 http://nats-3:8222
```

### Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  # Scrape NATS exporter
  - job_name: "nats"
    static_configs:
      - targets:
          - "nats-exporter:7777"
    metrics_path: /metrics

  # Or scrape NATS servers directly (built-in /varz endpoint)
  - job_name: "nats-varz"
    metrics_path: /varz
    static_configs:
      - targets:
          - "nats-1:8222"
          - "nats-2:8222"
          - "nats-3:8222"
    params:
      # Return Prometheus-compatible metrics format
      format: ["prometheus"]
```

### Key Prometheus Metrics

```
# Server health
nats_varz_connections             # Current connections
nats_varz_total_connections       # Lifetime total connections
nats_varz_slow_consumers          # Current slow consumers
nats_varz_in_msgs                 # Total inbound messages
nats_varz_out_msgs                # Total outbound messages
nats_varz_in_bytes                # Total inbound bytes
nats_varz_out_bytes               # Total outbound bytes
nats_varz_mem                     # Server RSS memory (bytes)
nats_varz_cpu                     # Server CPU usage (percentage)

# JetStream
nats_server_jetstream_streams        # Number of streams
nats_server_jetstream_consumers      # Number of consumers
nats_server_jetstream_store_used     # Disk storage used
nats_server_jetstream_store_reserved # Disk storage reserved
nats_server_jetstream_mem_used       # Memory storage used
nats_server_jetstream_mem_reserved   # Memory storage reserved

# Cluster
nats_routez_num_routes               # Number of active cluster routes
```

### Critical Alert Rules

```yaml
# prometheus-alerts.yml
groups:
  - name: nats
    rules:
      - alert: NATSServerDown
        expr: up{job="nats"} == 0
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "NATS server {{ $labels.instance }} is down"

      - alert: NATSSlowConsumers
        expr: nats_varz_slow_consumers > 0
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: "{{ $value }} slow consumer(s) on {{ $labels.instance }}"

      - alert: NATSHighConnections
        expr: nats_varz_connections > (nats_varz_max_connections * 0.85)
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "NATS connections at {{ $value | humanize }}% of max"

      - alert: NATSJetStreamStorageHigh
        expr: >
          (nats_server_jetstream_store_used / nats_server_jetstream_store_reserved) > 0.85
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "JetStream storage at {{ $value | humanizePercentage }}"

      - alert: NATSJetStreamMemoryHigh
        expr: >
          (nats_server_jetstream_mem_used / nats_server_jetstream_mem_reserved) > 0.80
        for: 5m
        labels: { severity: warning }

      - alert: NATSNoMetaLeader
        expr: nats_server_jetstream_meta_leader == 0
        for: 30s
        labels: { severity: critical }
        annotations:
          summary: "No JetStream meta leader — all JS API operations will fail"

      - alert: NATSHighServerMemory
        expr: nats_varz_mem > 4294967296  # 4GB
        for: 10m
        labels: { severity: warning }

      - alert: NATSClusterRouteDown
        expr: nats_routez_num_routes < 2
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "Cluster route count dropped to {{ $value }} (expected 2+ for 3-node)"
```

### Grafana Dashboard

Import the official NATS Grafana dashboard or build custom panels:

**Recommended panels:**

| Panel | Query | Type |
|-------|-------|------|
| Messages/sec | `rate(nats_varz_in_msgs[5m])` | Time series |
| Bytes/sec | `rate(nats_varz_in_bytes[5m])` | Time series |
| Connections | `nats_varz_connections` | Gauge |
| Slow consumers | `nats_varz_slow_consumers` | Stat |
| JetStream storage % | `nats_server_jetstream_store_used / nats_server_jetstream_store_reserved` | Gauge |
| Consumer lag | `nats_consumer_ack_pending` | Time series per consumer |
| Server CPU | `nats_varz_cpu` | Time series |
| Server memory | `nats_varz_mem` | Time series |

```json
{
  "dashboard": {
    "title": "NATS Cluster Overview",
    "panels": [
      {
        "title": "Message Rate",
        "type": "timeseries",
        "targets": [
          {"expr": "sum(rate(nats_varz_in_msgs[5m]))"}
        ]
      },
      {
        "title": "JetStream Storage Usage",
        "type": "gauge",
        "targets": [
          {"expr": "nats_server_jetstream_store_used / nats_server_jetstream_store_reserved * 100"}
        ],
        "fieldConfig": {
          "defaults": {"max": 100, "thresholds": {"steps": [
            {"value": 0, "color": "green"},
            {"value": 70, "color": "yellow"},
            {"value": 85, "color": "red"}
          ]}}
        }
      }
    ]
  }
}
```

---

## 11. Capacity Planning

### Estimating Storage

```
Daily storage = messages_per_second × avg_message_bytes × 86400 × num_replicas

Example:
  1000 msg/s × 1 KB × 86400s × 3 replicas = ~247 GB/day
  With 7-day retention: ~1.7 TB
```

### Estimating Memory

```
Connection memory = num_connections × ~10 KB (per connection overhead)
Subscription memory = num_subscriptions × ~1 KB
JetStream memory = configured max_mem (for memory-backed streams)

Example:
  10,000 connections × 10 KB = ~100 MB
  50,000 subscriptions × 1 KB = ~50 MB
  JetStream max_mem = 4 GB
  Total: ~4.15 GB + OS overhead → provision 8 GB RAM minimum
```

### Benchmarking Your Workload

```bash
# Throughput test
nats bench test.subject --pub 5 --sub 5 --msgs 1000000 --size 256

# Latency test
nats bench test.latency --pub 1 --sub 1 --msgs 10000 --size 128

# JetStream throughput
nats bench js.bench --js --pub 5 --sub 5 --msgs 100000 --size 512 \
  --storage file --replicas 3 --purge
```

---

## 12. Disaster Recovery

### Multi-Region with Mirrors

```bash
# Primary region: dc-east
nats stream add ORDERS --subjects="orders.>" --replicas=3 --server=nats://dc-east:4222

# DR region: dc-west (mirror)
nats stream add ORDERS_DR --mirror=ORDERS --replicas=3 --server=nats://dc-west:4222
```

### Failover Procedure

```bash
# 1. Verify primary is truly down
nats server ping --server=nats://dc-east:4222 --count=3

# 2. Check mirror lag (how much data might be lost)
nats stream info ORDERS_DR --server=nats://dc-west:4222

# 3. Convert mirror to standalone stream (breaks mirror link)
nats stream edit ORDERS_DR --server=nats://dc-west:4222 \
  --subjects="orders.>" \
  --remove-mirror

# 4. Update DNS / client configuration to point to dc-west

# 5. After primary recovery, re-mirror back:
nats stream edit ORDERS --server=nats://dc-east:4222 \
  --mirror=ORDERS_DR \
  --subjects=""
```

### RPO and RTO Guidelines

| Configuration | RPO | RTO |
|--------------|-----|-----|
| Single cluster, 3 replicas | 0 (within cluster) | Automatic (Raft failover <5s) |
| Super-cluster with mirrors | Seconds (mirror lag) | Minutes (manual mirror promotion) |
| Backup/restore | Hours (last backup) | Minutes–hours (restore time) |
