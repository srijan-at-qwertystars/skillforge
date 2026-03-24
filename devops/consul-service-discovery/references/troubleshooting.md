# Consul Troubleshooting Guide

## Table of Contents

- [Gossip Protocol Issues](#gossip-protocol-issues)
  - [Node Flapping](#node-flapping)
  - [Split Brain](#split-brain)
  - [Gossip Encryption Mismatches](#gossip-encryption-mismatches)
- [Raft Leadership Problems](#raft-leadership-problems)
  - [No Leader Elected](#no-leader-elected)
  - [Leader Instability](#leader-instability)
  - [Removing Failed Peers](#removing-failed-peers)
  - [Autopilot Issues](#autopilot-issues)
- [ACL Troubleshooting](#acl-troubleshooting)
  - [Token Resolution](#token-resolution)
  - [Policy and Role Debugging](#policy-and-role-debugging)
  - [Common ACL Errors](#common-acl-errors)
  - [ACL Replication](#acl-replication)
- [DNS Resolution Failures](#dns-resolution-failures)
  - [DNS Not Responding](#dns-not-responding)
  - [Stale DNS Results](#stale-dns-results)
  - [Forwarding Issues](#dns-forwarding-issues)
  - [DNS Caching Problems](#dns-caching-problems)
- [Connect Proxy Issues](#connect-proxy-issues)
  - [Sidecar Not Starting](#sidecar-not-starting)
  - [mTLS Failures](#mtls-failures)
  - [Upstream Connectivity](#upstream-connectivity)
  - [Envoy Debugging](#envoy-debugging)
- [Anti-Entropy Sync Delays](#anti-entropy-sync-delays)
  - [Understanding Anti-Entropy](#understanding-anti-entropy)
  - [Diagnosing Sync Issues](#diagnosing-sync-issues)
  - [Tuning Sync Intervals](#tuning-sync-intervals)
- [Performance Tuning](#performance-tuning)
  - [Stale Reads](#stale-reads)
  - [Consistency Modes](#consistency-modes)
  - [Server Performance](#server-performance)
  - [Client Performance](#client-performance)
  - [Monitoring Key Metrics](#monitoring-key-metrics)
- [Certificate Rotation Failures](#certificate-rotation-failures)
  - [Built-in CA Rotation](#built-in-ca-rotation)
  - [Vault CA Provider Issues](#vault-ca-provider-issues)
  - [Manual Certificate Rotation](#manual-certificate-rotation)
  - [Leaf Certificate Expiry](#leaf-certificate-expiry)

---

## Gossip Protocol Issues

### Node Flapping

**Symptoms:** Nodes rapidly alternate between alive/failed state. Frequent `member: deregistered` / `member: joined` log entries.

**Diagnosis:**

```bash
# Check member status for flapping nodes
consul members -detailed | grep -i suspect

# Review agent logs for gossip activity
journalctl -u consul --since "1 hour ago" | grep -i "memberlist\|suspect\|dead\|alive"

# Check network latency between nodes
consul rtt node-a node-b
consul rtt -wan dc1 dc2

# Monitor gossip health
consul operator raft list-peers
```

**Common causes and fixes:**

| Cause | Fix |
|-------|-----|
| High network latency / packet loss | Tune gossip intervals: increase `gossip_lan.probe_interval` and `gossip_lan.suspicion_mult` |
| CPU contention | Ensure Consul has dedicated CPU; check for noisy neighbors |
| Overloaded agent | Reduce number of services/checks per agent |
| MTU issues | Test with `ping -M do -s 1472` to verify MTU; adjust if fragments are dropped |
| Clock skew | Ensure NTP is configured and synced |

**Tuning gossip parameters:**

```hcl
gossip_lan {
  gossip_interval     = "200ms"    # Default: 200ms. Increase if network is slow
  gossip_nodes        = 4          # Default: 3. Nodes to gossip to per interval
  probe_interval      = "2s"       # Default: 1s. Increase for high-latency networks
  probe_timeout       = "1s"       # Default: 500ms. Timeout for probe ack
  retransmit_mult     = 5          # Default: 4. Messages retransmitted retransmit_mult * log(N) times
  suspicion_mult      = 6          # Default: 4. Time before suspect node declared dead
}
```

### Split Brain

**Symptoms:** Multiple leaders, inconsistent data between server groups, cluster partition.

**Diagnosis:**

```bash
# Each server shows different leaders
consul operator raft list-peers

# Check from multiple servers
for s in server1 server2 server3; do
  echo "=== $s ==="
  ssh $s consul operator raft list-peers
done

# Verify network connectivity between servers
for s in server1 server2 server3; do
  nc -zv $s 8300  # RPC port
  nc -zv $s 8301  # Serf LAN
done
```

**Resolution:**

1. **Identify the legitimate leader** (the partition with quorum)
2. **Fix network** between server partitions
3. If servers in the minority partition have diverged:
   ```bash
   # On the minority partition servers, stop and rejoin
   consul leave
   # Remove data dir, restart, and rejoin
   rm -rf /opt/consul/data/*
   consul agent -config-dir=/etc/consul.d -join=<leader-ip>
   ```
4. If all else fails, restore from snapshot:
   ```bash
   consul snapshot restore last-good-backup.snap
   ```

### Gossip Encryption Mismatches

**Symptoms:** Nodes cannot join the cluster, log shows `encrypt` errors.

```bash
# Verify all nodes use the same key
consul keyring -list

# Rotate key (zero-downtime):
NEW_KEY=$(consul keygen)
consul keyring -install "$NEW_KEY"   # Install new key on all nodes
consul keyring -use "$NEW_KEY"       # Switch primary key
consul keyring -remove "$OLD_KEY"    # Remove old key
```

---

## Raft Leadership Problems

### No Leader Elected

**Symptoms:** All reads and writes fail. `consul operator raft list-peers` shows no leader. Logs show repeated election attempts.

**Diagnosis:**

```bash
# Check Raft peers
consul operator raft list-peers

# Check if quorum is possible (need majority of voters)
# 3 servers = need 2; 5 servers = need 3

# Check server logs for election issues
journalctl -u consul | grep -i "election\|leader\|heartbeat\|quorum"

# Verify server connectivity (port 8300)
consul members -detailed | grep server
```

**Common fixes:**

1. **Insufficient servers for quorum:**
   ```bash
   # If servers are down, bring them back
   systemctl start consul
   
   # If a server is permanently lost, remove it
   consul operator raft remove-peer -address="10.0.1.3:8300"
   ```

2. **Disk I/O too slow** (Raft requires fsync):
   ```bash
   # Check disk latency
   dd if=/dev/zero of=/opt/consul/data/test bs=512 count=1000 oflag=dsync
   # Should be < 10ms for good performance
   ```

3. **Network partition** — ensure port 8300 is open between all servers

### Leader Instability

**Symptoms:** Leader changes frequently, write operations sporadically fail.

**Diagnosis and fixes:**

```bash
# Monitor leader elections
consul monitor -log-level=info | grep -i leader

# Check Raft timing
consul info | grep -A 10 raft
```

**Tuning Raft performance:**

```hcl
performance {
  raft_multiplier = 1    # Default: 5 (development). Production: 1
  # Lower = tighter timeouts, faster failover, requires better network
  # Higher = more tolerant of network jitter, slower failover
}
```

`raft_multiplier` scales these timers:

| Parameter | Multiplier=1 | Multiplier=5 (default) |
|-----------|-------------|----------------------|
| HeartbeatTimeout | 1000ms | 5000ms |
| ElectionTimeout | 1000ms | 5000ms |
| LeaderLeaseTimeout | 500ms | 2500ms |

### Removing Failed Peers

```bash
# List current peers
consul operator raft list-peers

# Remove by address (when node is unreachable)
consul operator raft remove-peer -address="10.0.1.3:8300"

# Remove by ID (Consul 1.7+)
consul operator raft remove-peer -id="server-3-id"

# Force remove from a single-server cluster (disaster recovery)
# Stop Consul, then:
consul operator raft remove-peer -address="10.0.1.2:8300"
```

### Autopilot Issues

Autopilot automates dead server cleanup and stable server introduction.

```bash
# Check autopilot health
consul operator autopilot get-config
consul operator autopilot state

# Common tuning
consul operator autopilot set-config \
  -cleanup-dead-servers=true \
  -last-contact-threshold=500ms \
  -max-trailing-logs=1000 \
  -server-stabilization-time=10s
```

---

## ACL Troubleshooting

### Token Resolution

**Symptoms:** `Permission denied` or `ACL not found` errors.

**Diagnosis workflow:**

```bash
# 1. Verify token exists and is not expired
consul acl token read -id <token-accessor-id>

# 2. Check what policies are attached
consul acl token read -id <token-accessor-id> -format=json | jq '.Policies, .Roles, .ServiceIdentities, .NodeIdentities'

# 3. Test token permissions
CONSUL_HTTP_TOKEN=<secret-id> consul catalog services
CONSUL_HTTP_TOKEN=<secret-id> consul kv get config/test

# 4. Check if ACLs are enabled
consul info | grep -A 5 consul

# 5. Check ACL configuration
consul acl token list  # Requires management token
```

**Common token issues:**

| Error | Cause | Fix |
|-------|-------|-----|
| `ACL not found` | Token doesn't exist or was deleted | Create new token |
| `Permission denied` | Token lacks required policy | Add policy/role to token |
| `ACL disabled` | ACLs not enabled on this agent | Set `acl.enabled = true` |
| `token ... is expired` | Token TTL exceeded | Create new token or set no TTL |

### Policy and Role Debugging

```bash
# Read a policy to see its rules
consul acl policy read -name web-policy

# Validate policy syntax before applying
consul acl policy create -name test -rules - <<'EOF'
service "web" { policy = "write" }
service_prefix "" { policy = "read" }
EOF

# Check effective permissions for a token
# (No built-in command; test empirically)
CONSUL_HTTP_TOKEN=<secret> consul kv put test/key value  # Test write
CONSUL_HTTP_TOKEN=<secret> consul kv get test/key        # Test read

# List all policies
consul acl policy list

# List all roles
consul acl role list
consul acl role read -name my-role
```

**ACL rule precedence:** Most specific rule wins. Exact match > prefix match > default policy.

```hcl
# Example: This allows writing to "web" but only reading other services
service "web" { policy = "write" }
service_prefix "" { policy = "read" }
# "web" matches the exact rule (write), "api" matches the prefix (read)
```

### Common ACL Errors

**"No cluster leader"** during ACL operations:
- ACL operations require a leader (they write to Raft)
- Fix: Ensure Raft has a stable leader first

**ACL bootstrap fails with "already bootstrapped":**
```bash
# Reset bootstrap (requires server access)
consul acl bootstrap  # Fails if already done

# If management token is lost, reset:
# 1. Create reset file
echo '{"ID": "reset-id", "Secret": "reset-secret"}' > /opt/consul/data/acl-bootstrap-reset
# 2. Or reset via API on a fresh cluster
```

**Agent token not set (agent can't sync with servers):**
```bash
# Set agent token
consul acl set-agent-token agent <token-secret>
consul acl set-agent-token default <token-secret>

# In config file
acl {
  tokens {
    agent   = "agent-token-secret"
    default = "default-token-secret"
  }
}
```

### ACL Replication

In multi-DC setups, ACLs are managed in the primary DC and replicated.

```bash
# Check replication status
curl -s http://localhost:8500/v1/acl/replication | jq

# Expected output shows enabled=true, running=true
# ReplicatedIndex should be close to the primary's index
```

**Replication lag diagnosis:**
```bash
# On primary: get current index
curl -s http://localhost:8500/v1/acl/token/list | head -1

# On secondary: check replicated index
curl -s http://localhost:8500/v1/acl/replication | jq '.ReplicatedIndex'

# If stuck, check for errors
journalctl -u consul | grep -i "acl replication\|replicat"
```

---

## DNS Resolution Failures

### DNS Not Responding

```bash
# Test DNS directly
dig @127.0.0.1 -p 8600 consul.service.consul

# Check if DNS port is listening
ss -ulnp | grep 8600
ss -tlnp | grep 8600

# Verify DNS is enabled in config (enabled by default)
consul info | grep dns

# Check DNS-specific config
consul agent -dev -dns-port=8600  # Ensure correct port

# Check for recursion if querying non-.consul domains
dig @127.0.0.1 -p 8600 google.com
# Consul only serves .consul domain by default
```

### Stale DNS Results

```bash
# DNS uses the agent's local catalog, which may be stale
# Force a fresh lookup by using the API instead
curl -s 'http://localhost:8500/v1/health/service/web?passing=true'

# Configure DNS staleness tolerance
# In Consul config:
dns_config {
  allow_stale       = true    # Allow non-leader to serve DNS (default: true)
  max_stale         = "87600h" # Max staleness (default: 87600h = 10 years)
  node_ttl          = "10s"    # TTL for node lookups
  service_ttl {
    "*" = "5s"                 # TTL for service lookups
  }
  use_cache         = true     # Use agent cache for DNS
  cache_max_age     = "5s"
}
```

### DNS Forwarding Issues

**systemd-resolved not forwarding .consul:**

```bash
# Verify configuration
resolvectl status | grep -A 5 consul

# Test
resolvectl query web.service.consul

# If not working, restart resolved
sudo systemctl restart systemd-resolved

# Alternative: use direct stub
echo "server=/consul/127.0.0.1#8600" | sudo tee /etc/dnsmasq.d/consul.conf
```

**dnsmasq not forwarding:**

```bash
# Test dnsmasq directly
dig @127.0.0.1 -p 53 web.service.consul

# Check dnsmasq logs
journalctl -u dnsmasq | tail -20

# Verify config
cat /etc/dnsmasq.d/consul.conf
# Should contain: server=/consul/127.0.0.1#8600
```

### DNS Caching Problems

**Negative caching causing issues after service registration:**

```bash
# SOA record TTL controls negative caching
# Reduce in Consul config:
dns_config {
  soa {
    min_ttl = 0    # Minimum SOA TTL (controls negative cache)
  }
}

# Flush local DNS cache
sudo systemd-resolve --flush-caches  # systemd-resolved
sudo killall -HUP dnsmasq            # dnsmasq
```

---

## Connect Proxy Issues

### Sidecar Not Starting

**Symptoms:** `consul connect envoy` fails or sidecar proxy doesn't start.

```bash
# Check if the sidecar service is registered
consul catalog services | grep sidecar

# Verify the parent service has connect stanza
consul services | grep -A 5 web

# Check proxy registration
curl -s http://localhost:8500/v1/agent/service/web-sidecar-proxy | jq

# Common errors:
# "No known Consul servers" — agent not connected to cluster
consul members

# "service ... not found" — parent service not registered
consul services

# Envoy binary not found
which envoy
envoy --version
```

### mTLS Failures

**Symptoms:** `TLS handshake` errors, connections refused between services.

```bash
# Check CA is initialized
curl -s http://localhost:8500/v1/connect/ca/roots | jq '.Roots[0].Active'

# Verify leaf certificate for service
curl -s http://localhost:8500/v1/agent/connect/ca/leaf/web | jq '.ValidBefore'

# Check certificate chain
openssl s_client -connect localhost:21000 -servername web.default.dc1.internal \
  -CAfile /path/to/ca.pem 2>&1 | openssl x509 -noout -subject -issuer -dates

# Check Envoy certificate status
curl -s localhost:19000/certs | jq

# Verify intentions allow the connection
consul intention check web api
```

**Common mTLS fixes:**

1. **CA not initialized:** `consul connect ca set-config -config-file ca.json`
2. **Intentions blocking:** `consul intention create -allow web api`
3. **Clock skew causing cert validation failure:** Fix NTP
4. **Wrong SPIFFE ID:** Verify service names match

### Upstream Connectivity

**Symptoms:** Application can't reach upstream via `localhost:<upstream_port>`.

```bash
# Verify upstream is configured
curl -s http://localhost:8500/v1/agent/service/web-sidecar-proxy | jq '.Proxy.Upstreams'

# Check Envoy upstream cluster health
curl -s localhost:19000/clusters | grep -A 3 api

# Test upstream directly
curl -v http://localhost:9191/   # Local bind port for upstream

# Check Envoy listeners
curl -s localhost:19000/listeners

# If upstream shows "no healthy upstream" — check:
# 1. Upstream service is registered and healthy
consul catalog service api
# 2. Intentions allow the connection
consul intention check web api
# 3. Upstream sidecar proxy is running
curl -s http://localhost:8500/v1/health/service/api?passing=true | jq '.[].Checks'
```

### Envoy Debugging

```bash
# Increase Envoy log level dynamically
curl -X POST "localhost:19000/logging?level=debug"

# Check specific component logs
curl -X POST "localhost:19000/logging?connection=trace"
curl -X POST "localhost:19000/logging?upstream=debug"

# Dump full Envoy config
curl -s localhost:19000/config_dump | jq

# Check Envoy stats for errors
curl -s localhost:19000/stats | grep -E "cx_connect_fail|membership_healthy|retry"

# Reset stats
curl -X POST localhost:19000/reset_counters

# Verify xDS connection to Consul
curl -s localhost:19000/clusters | grep consul
```

---

## Anti-Entropy Sync Delays

### Understanding Anti-Entropy

Consul agents periodically synchronize their local state with the servers (anti-entropy). If a service is registered on an agent but hasn't appeared in the catalog, anti-entropy hasn't run yet.

### Diagnosing Sync Issues

```bash
# Check if service is on agent but not in catalog
# Agent-local:
curl -s http://localhost:8500/v1/agent/services | jq keys
# Catalog (server-side):
curl -s http://localhost:8500/v1/catalog/service/web | jq '.[].ServiceID'

# If present on agent but not catalog, anti-entropy is delayed

# Check agent logs for sync activity
journalctl -u consul | grep -i "anti-entropy\|sync\|synced"

# Check if agent is connected to a server
consul info | grep -A 5 "serf_lan"
```

### Tuning Sync Intervals

Anti-entropy runs at configurable intervals. In large clusters, consider:

```hcl
# Consul agent config
performance {
  raft_multiplier = 1    # Tighter timings in production
}

# Anti-entropy interval is not directly configurable;
# it's tied to the gossip protocol and internal state.
# However, you can force a sync:
consul reload   # Triggers re-sync of all services and checks

# For large clusters, reduce the number of services per agent
# and consider using external service registration (catalog API)
```

---

## Performance Tuning

### Stale Reads

Stale reads allow any server (not just the leader) to serve read queries. This reduces load on the leader and improves read throughput.

```bash
# Use stale mode for read-heavy workloads
curl 'http://localhost:8500/v1/catalog/service/web?stale'
curl 'http://localhost:8500/v1/kv/config/key?stale'
curl 'http://localhost:8500/v1/health/service/web?stale&passing=true'

# Check staleness of response
# X-Consul-LastContact header shows milliseconds since last contact with leader
```

### Consistency Modes

| Mode | Guarantee | Performance | Use Case |
|------|-----------|-------------|----------|
| `default` | Leader-verified | Medium | General use |
| `consistent` | Leader + quorum verified | Slowest | Critical reads (locks, elections) |
| `stale` | Any server, may be behind | Fastest | High-throughput reads, DNS, monitoring |

```bash
# Default mode (leader forwards if needed)
curl http://localhost:8500/v1/kv/key

# Consistent mode (leader confirms with quorum)
curl 'http://localhost:8500/v1/kv/key?consistent'

# Stale mode (any server responds)
curl 'http://localhost:8500/v1/kv/key?stale'
```

**DNS consistency:**

```hcl
dns_config {
  allow_stale  = true       # Allow stale reads for DNS (default: true)
  max_stale    = "87600h"   # Accept any staleness for DNS
  use_cache    = true       # Use agent-local cache
}
```

### Server Performance

```hcl
# Production server tuning
performance {
  raft_multiplier = 1   # Tighter Raft timings
}

limits {
  http_max_conns_per_client = 200   # Default: 100
  rpc_max_conns_per_client  = 100   # Default: 100
  rpc_rate                  = 1000  # RPC rate limit (requests/sec)
  rpc_max_burst             = 2000  # Burst allowance
}

# Use SSD storage for Raft data
# Recommended: dedicated disk for /opt/consul/data
# Minimum IOPS: 1000+ for busy clusters

# Memory tuning — Consul is Go-based
# Set GOGC for garbage collection tuning (default: 100)
# Lower GOGC = more frequent GC, less memory, more CPU
# Higher GOGC = less frequent GC, more memory, less CPU
# Environment: GOGC=50 for memory-constrained, GOGC=200 for CPU-constrained
```

### Client Performance

```hcl
# Reduce gossip overhead on clients
gossip_lan {
  gossip_nodes = 3      # Reduce if cluster is large
}

# Cache settings for the agent
cache {
  entry_fetch_max_burst = 2
  entry_fetch_rate      = 0.333  # ~1 per 3 seconds
}

# If running many services, consider batch registration
# and longer health check intervals
check {
  interval = "30s"   # Instead of 10s for non-critical checks
  timeout  = "5s"
}
```

### Monitoring Key Metrics

```bash
# Telemetry endpoint (if enabled)
curl -s http://localhost:8500/v1/agent/metrics | jq

# Key metrics to monitor:
# consul.raft.leader.lastContact     — Time since leader heard from followers (< 200ms)
# consul.raft.commitTime             — Time to commit Raft entry (< 50ms)
# consul.rpc.query                   — RPC query rate
# consul.rpc.request                 — RPC write rate
# consul.serf.member.flap            — Gossip flap count (should be 0)
# consul.catalog.register            — Registration rate
# consul.runtime.alloc_bytes         — Memory allocation
# consul.acl.resolveToken            — ACL resolution time
```

**Enable telemetry:**

```hcl
telemetry {
  prometheus_retention_time = "60s"
  disable_hostname          = true

  # Or push to StatsD/DogStatsD
  statsd_address  = "localhost:8125"
  metrics_prefix  = "consul"
}
```

---

## Certificate Rotation Failures

### Built-in CA Rotation

```bash
# Check current CA configuration
consul connect ca get-config

# View active root certificate
curl -s http://localhost:8500/v1/connect/ca/roots | jq '.Roots[] | select(.Active==true) | {Name, NotAfter}'

# Rotate to new root CA (generates new root, cross-signs)
consul connect ca set-config -config-file - <<'EOF'
{
  "Provider": "consul",
  "Config": {
    "LeafCertTTL": "72h",
    "IntermediateCertTTL": "8760h",
    "RootCertTTL": "87600h",
    "RotationPeriod": "2160h",
    "PrivateKeyType": "ec",
    "PrivateKeyBits": 256
  }
}
EOF

# After rotation, verify old root is still trusted (cross-signing)
curl -s http://localhost:8500/v1/connect/ca/roots | jq '.Roots | length'
# Should show 2 roots during rotation period
```

### Vault CA Provider Issues

```bash
# Check Vault CA provider config
consul connect ca get-config | jq

# Common Vault issues:
# 1. Vault token expired
# 2. Vault PKI backend not mounted
# 3. Vault policy insufficient

# Verify Vault PKI
vault read pki/cert/ca
vault list pki/certs

# Set Vault as CA provider
consul connect ca set-config -config-file - <<'EOF'
{
  "Provider": "vault",
  "Config": {
    "Address": "https://vault.service.consul:8200",
    "Token": "s.VAULT_TOKEN",
    "RootPKIPath": "connect-root",
    "IntermediatePKIPath": "connect-intermediate",
    "LeafCertTTL": "72h",
    "RotationPeriod": "2160h",
    "IntermediateCertTTL": "8760h",
    "PrivateKeyType": "ec",
    "PrivateKeyBits": 256
  }
}
EOF

# Check Vault-related errors
journalctl -u consul | grep -i "vault\|ca provider\|certificate"
```

### Manual Certificate Rotation

**When auto-rotation fails:**

```bash
# 1. Check current state
consul connect ca get-config
curl -s http://localhost:8500/v1/connect/ca/roots | jq

# 2. Force rotation by setting new config
consul connect ca set-config -config-file new-ca.json

# 3. Monitor leaf certificate regeneration
# Envoy proxies will pick up new certs automatically via xDS
# Check Envoy cert status:
curl -s localhost:19000/certs | jq '.. | .valid_from? // empty'

# 4. If stuck, restart sidecar proxies
# This forces them to fetch new leaf certificates
consul connect envoy -sidecar-for web -admin-bind localhost:19000
```

### Leaf Certificate Expiry

**Symptoms:** mTLS connections fail, Envoy logs show certificate expired errors.

```bash
# Check leaf cert expiry for a service
curl -s http://localhost:8500/v1/agent/connect/ca/leaf/web | jq '{ValidAfter, ValidBefore}'

# Check from Envoy
curl -s localhost:19000/certs | jq '.certificates[].cert_chain[].days_until_expiration'

# If leaf certs aren't renewing:
# 1. Verify CA is healthy
consul connect ca get-config
# 2. Check agent logs
journalctl -u consul | grep -i "leaf\|certificate\|renew"
# 3. Restart agent to force renewal
consul reload
# 4. If still failing, restart the agent fully
systemctl restart consul
```

**Preventive measures:**

```hcl
# Set appropriate TTLs
connect {
  ca_config {
    leaf_cert_ttl          = "72h"    # Default: 72h
    # Consul renews at ~70% of TTL
    # Ensure rotation_period < leaf_cert_ttl
    intermediate_cert_ttl  = "8760h"  # 1 year
    root_cert_ttl          = "87600h" # 10 years
  }
}
```

**Monitoring certificate expiry:**

```bash
# Script to check all proxy certificates
for svc in $(consul catalog services | grep -v consul); do
  echo "=== $svc ==="
  curl -s "http://localhost:8500/v1/agent/connect/ca/leaf/$svc" 2>/dev/null \
    | jq -r '"  Valid until: " + .ValidBefore' 2>/dev/null || echo "  No leaf cert"
done
```
