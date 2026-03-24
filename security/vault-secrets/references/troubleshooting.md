# Vault Troubleshooting Guide

## Table of Contents

- [Common Errors](#common-errors)
  - [Permission Denied (403)](#permission-denied-403)
  - [Seal Status Issues](#seal-status-issues)
  - [Lease Not Found](#lease-not-found)
  - [Token Expired / Invalid Token](#token-expired--invalid-token)
  - [Backend Connection Errors](#backend-connection-errors)
- [Debugging Auth Methods](#debugging-auth-methods)
  - [AppRole Issues](#approle-issues)
  - [Kubernetes Auth Issues](#kubernetes-auth-issues)
  - [OIDC Auth Issues](#oidc-auth-issues)
  - [LDAP Auth Issues](#ldap-auth-issues)
- [Storage Backend Issues](#storage-backend-issues)
  - [Raft Storage](#raft-storage)
  - [Consul Storage](#consul-storage)
- [HA and Failover Problems](#ha-and-failover-problems)
  - [Leader Election Failures](#leader-election-failures)
  - [Split-Brain Scenarios](#split-brain-scenarios)
  - [Performance Standby Issues](#performance-standby-issues)
- [Audit Log Analysis](#audit-log-analysis)
  - [Reading Audit Logs](#reading-audit-logs)
  - [Correlating HMAC Values](#correlating-hmac-values)
  - [Common Audit Patterns](#common-audit-patterns)
- [Performance Tuning](#performance-tuning)
  - [Identifying Bottlenecks](#identifying-bottlenecks)
  - [Tuning Vault Configuration](#tuning-vault-configuration)
  - [Client-Side Optimizations](#client-side-optimizations)
- [Disaster Recovery Procedures](#disaster-recovery-procedures)
  - [Raft Snapshot Restore](#raft-snapshot-restore)
  - [Recovering from Data Loss](#recovering-from-data-loss)
  - [Emergency Break-Glass](#emergency-break-glass)

---

## Common Errors

### Permission Denied (403)

**Error:** `Error making API request: URL: PUT .../secret/data/myapp, Code: 403. Errors: 1 error occurred: * permission denied`

**Diagnosis Steps:**

```bash
# 1. Check what token you're using
vault token lookup

# 2. Check token's policies
vault token lookup -format=json | jq '.data.policies'

# 3. Check capabilities on the specific path
vault token capabilities secret/data/myapp/config

# 4. Read the policy to verify paths
vault policy read <policy-name>

# 5. Check if namespace is correct (Enterprise)
echo $VAULT_NAMESPACE
```

**Common Causes & Fixes:**

| Cause | Fix |
|-------|-----|
| KV v2 path missing `data/` prefix | Use `secret/data/myapp` not `secret/myapp` in policies |
| Wrong namespace | Set `VAULT_NAMESPACE` or use `-namespace=` flag |
| Policy uses `+` but path has multiple segments | Use `*` for multi-segment matches |
| Token expired or revoked | Create new token or re-authenticate |
| `deny` capability on parent path | Check for deny rules at parent paths |
| Case sensitivity | Paths are case-sensitive — verify exact casing |

**KV v2 Policy Gotcha:**

```hcl
# WRONG — This won't work for KV v2
path "secret/myapp/*" {
  capabilities = ["read"]
}

# CORRECT — KV v2 requires data/ prefix for read/write
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
# And metadata/ prefix for list
path "secret/metadata/myapp/*" {
  capabilities = ["list"]
}
```

### Seal Status Issues

**Error:** `Vault is sealed` or `error during core unsealing`

```bash
# Check seal status
vault status
# Key outputs: Sealed (true/false), Unseal Progress, Unseal Nonce

# Check server logs for seal errors
journalctl -u vault -f --no-pager | grep -i seal
```

**Auto-Unseal Failures:**

```bash
# AWS KMS — check IAM permissions
aws kms describe-key --key-id <key-id>
aws kms encrypt --key-id <key-id> --plaintext "test" 2>&1

# Common issues:
# - KMS key deleted or disabled
# - IAM role/policy missing kms:Encrypt, kms:Decrypt, kms:DescribeKey
# - Network connectivity to KMS endpoint blocked
# - AWS credentials expired (if not using IAM roles)

# Azure Key Vault — check service principal
az keyvault key show --vault-name <vault> --name <key>

# GCP CKMS — check service account
gcloud kms keys describe <key> --location=<loc> --keyring=<ring>
```

**Recovering from Failed Unseal:**

```bash
# If unseal keys are lost but recovery keys exist (auto-unseal)
vault operator generate-root -init
vault operator generate-root -nonce=<nonce> <recovery_key>
# Repeat for threshold, then decode

# If Shamir keys are partially available
vault operator unseal <key_share>  # Repeat until threshold met

# Nuclear option: re-initialize (DESTROYS ALL DATA)
vault operator init -key-shares=5 -key-threshold=3
```

### Lease Not Found

**Error:** `lease not found` or `lease is not renewable`

```bash
# Check if lease exists
vault write sys/leases/lookup lease_id="<lease_id>"

# List leases for a path
vault list sys/leases/lookup/database/creds/app-role

# Common causes:
# 1. Lease already expired — request new credentials
# 2. Lease was revoked — check audit logs
# 3. Max TTL exceeded — lease cannot be renewed past max_ttl
# 4. Backend revoked the credential (e.g., DB user dropped)
```

**Fixing Lease Issues:**

```bash
# Check lease configuration on the role
vault read database/roles/app-role
# Verify default_ttl and max_ttl values

# Tidy expired leases
vault write -f sys/leases/tidy

# Check lease count quotas (Enterprise)
vault read sys/quotas/lease-count/<name>

# Force revoke all stale leases for a mount
vault lease revoke -prefix -force database/creds/
```

### Token Expired / Invalid Token

**Error:** `permission denied` with `token not found` in audit logs

```bash
# Check token details
vault token lookup <token>

# If using VAULT_TOKEN env var
vault token lookup

# Check for orphan tokens (no parent)
vault token lookup -format=json | jq '.data.orphan'
```

**Token Renewal Patterns:**

```bash
# Check if token is renewable
vault token lookup -format=json | jq '.data.renewable'

# Renew before expiry
vault token renew -increment=1h

# Self-renewal in scripts
while true; do
  vault token renew -increment=1h 2>/dev/null || {
    echo "Token renewal failed — re-authenticating"
    # Re-authenticate via AppRole, K8s, etc.
  }
  sleep 1800  # Renew every 30 minutes
done
```

### Backend Connection Errors

**Error:** `error connecting to database` or `failed to verify connection`

```bash
# Database secrets engine
vault read database/config/mydb 2>&1

# Test connectivity from Vault server
# (run on the Vault server itself)
psql -h db.example.com -U vault_admin -d mydb -c "SELECT 1"

# Rotate the root credentials if they've changed
vault write -f database/rotate-root/mydb

# Re-configure the connection
vault write database/config/mydb \
  connection_url="postgresql://{{username}}:{{password}}@newhost:5432/mydb" \
  username="vault_admin" password="new_password"
```

---

## Debugging Auth Methods

### AppRole Issues

```bash
# Check role configuration
vault read auth/approle/role/my-app

# Verify role-id
vault read auth/approle/role/my-app/role-id

# Generate and test secret-id
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/my-app/secret-id)

# Test login
vault write auth/approle/login role_id="<role-id>" secret_id="$SECRET_ID"

# Common issues:
# - secret_id_num_uses exhausted → generate new secret-id
# - secret_id_ttl expired → generate new secret-id
# - CIDR binding mismatch → check secret_id_bound_cidrs and token_bound_cidrs
# - role not found → verify auth mount path
```

**Secret-ID Exhaustion Debugging:**

```bash
# Check secret-id accessors
vault list auth/approle/role/my-app/secret-id

# Look up specific secret-id
vault write auth/approle/role/my-app/secret-id/lookup \
  secret_id="<secret-id>"

# Check remaining uses
vault write auth/approle/role/my-app/secret-id/lookup \
  secret_id="<secret-id>" | grep -E "num_uses|ttl"
```

### Kubernetes Auth Issues

```bash
# Check configuration
vault read auth/kubernetes/config

# Common error: "service account not allowed"
# Fix: Check bound_service_account_names and bound_service_account_namespaces
vault read auth/kubernetes/role/app

# Test from a pod
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST \
  --data "{\"jwt\":\"$JWT\",\"role\":\"app\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq .

# Debug JWT contents
echo "$JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
# Check: "iss", "sub", "kubernetes.io/serviceaccount/namespace"
```

**Token Reviewer Issues:**

```bash
# Vault needs permission to validate service account tokens
# Check if token reviewer is configured
kubectl get clusterrolebinding vault-tokenreview 2>/dev/null

# Create if missing
kubectl create clusterrolebinding vault-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault

# For Kubernetes 1.24+, manually create long-lived token
kubectl create token vault -n vault --duration=8760h
```

### OIDC Auth Issues

```bash
# Check OIDC configuration
vault read auth/oidc/config

# Test OIDC discovery URL
curl -s https://accounts.google.com/.well-known/openid-configuration | jq .

# Common issues:
# - redirect_uri mismatch → must match exactly in IDP and Vault role
# - Clock skew → ensure Vault server time is synced (NTP)
# - Missing claims → check user_claim, groups_claim mappings
# - bound_audiences mismatch → verify oidc_client_id matches

# Debug: Enable verbose auth logging
vault auth tune -listing-visibility=unauth oidc/
```

### LDAP Auth Issues

```bash
# Check configuration
vault read auth/ldap/config

# Test LDAP connectivity from Vault server
ldapsearch -H ldaps://ldap.example.com -D "cn=vault,ou=services,dc=example,dc=com" \
  -w password -b "ou=users,dc=example,dc=com" "(uid=testuser)"

# Test login
vault login -method=ldap username=testuser

# Common issues:
# - TLS certificate verification → set insecure_tls=true for testing
# - userattr mismatch → try "sAMAccountName" for AD, "uid" for OpenLDAP
# - groupattr mismatch → try "memberOf" for AD, "cn" for OpenLDAP
# - userdn too restrictive → broaden the search base
```

---

## Storage Backend Issues

### Raft Storage

```bash
# Check Raft cluster status
vault operator raft list-peers

# Example output:
# Node       Address             State       Voter
# vault-1    vault-1:8201        leader      true
# vault-2    vault-2:8201        follower    true
# vault-3    vault-3:8201        follower    true

# Check autopilot health
vault operator raft autopilot state

# Remove a dead/failed peer
vault operator raft remove-peer vault-3

# Force a leader step-down
vault operator step-down
```

**Raft Data Corruption:**

```bash
# Check Raft storage integrity
vault operator raft snapshot save /tmp/raft-backup.snap
# If snapshot fails, data may be corrupted

# Restore from snapshot (DESTRUCTIVE)
vault operator raft snapshot restore /tmp/raft-backup.snap

# If cluster is in bad state, force new cluster from single node:
# 1. Stop all Vault nodes
# 2. On one node, set raft config to bootstrap
# 3. Start that node, restore snapshot
# 4. Join other nodes
```

**Raft Performance Issues:**

```bash
# Monitor Raft metrics
curl -s $VAULT_ADDR/v1/sys/metrics?format=prometheus | grep raft

# Key metrics:
# vault.raft.apply — Raft log apply latency
# vault.raft.commitTime — Commit time
# vault.raft.leader.dispatchLog — Log dispatch time
# vault.raft.rpc.appendEntries — Append entries RPC time

# Increase Raft snapshot interval if I/O-bound
# vault.hcl:
# storage "raft" {
#   snapshot_threshold = 16384  # default 8192
#   trailing_logs     = 20000  # default 10000
# }
```

### Consul Storage

```bash
# Check Consul health
consul members
consul operator raft list-peers

# Check Vault's KV data in Consul
consul kv get -recurse vault/

# Consul ACL issues — verify Vault's Consul token
consul acl token read -id <vault-consul-token-id>

# Required Consul permissions:
# key_prefix "vault/" { policy = "write" }
# node_prefix "" { policy = "read" }
# service "vault" { policy = "write" }
# session_prefix "" { policy = "write" }
```

---

## HA and Failover Problems

### Leader Election Failures

```bash
# Check cluster members
vault operator members

# Force leader step-down
vault operator step-down

# Check for network partitions
# Each node should be able to reach others on cluster_addr (port 8201)
curl -k https://vault-2:8201/v1/sys/health

# Verify cluster_addr and api_addr are correct
vault read sys/config/state/sanitized
```

### Split-Brain Scenarios

If multiple nodes think they're the leader:

```bash
# 1. Identify actual leader
for node in vault-1 vault-2 vault-3; do
  echo "$node: $(curl -sk https://$node:8200/v1/sys/leader | jq -r .is_self)"
done

# 2. Step down all nodes except desired leader
vault operator step-down  # Run on incorrect leaders

# 3. If Raft, check quorum
vault operator raft list-peers

# 4. Nuclear option: restart all nodes sequentially
systemctl stop vault  # All nodes
systemctl start vault # One at a time, starting with node that has latest data
```

### Performance Standby Issues

```bash
# Check if node is a performance standby
vault status -format=json | jq '.performance_standby'

# Performance standbys returning stale data
# Client fix: use X-Vault-Inconsistent header
curl -H "X-Vault-Inconsistent: forward-active-node" ...

# Check replication lag
vault read sys/replication/status -format=json | jq '.data'
```

---

## Audit Log Analysis

### Reading Audit Logs

Audit logs are JSON, one entry per line. Every request and response is logged.

```bash
# Stream audit log
tail -f /var/log/vault/audit.log | jq .

# Find all operations by a specific token accessor
jq 'select(.auth.accessor == "accessor_value")' /var/log/vault/audit.log

# Find all permission denied errors
jq 'select(.error != "" and .error != null)' /var/log/vault/audit.log

# Find all secret reads
jq 'select(.request.operation == "read" and (.request.path | startswith("secret/")))' \
  /var/log/vault/audit.log

# Find requests in a time window
jq 'select(.time >= "2025-01-15T10:00:00Z" and .time <= "2025-01-15T11:00:00Z")' \
  /var/log/vault/audit.log

# Count operations by path
jq -r '.request.path' /var/log/vault/audit.log | sort | uniq -c | sort -rn | head -20
```

### Correlating HMAC Values

Audit logs HMAC sensitive values. To find which token generated a log entry:

```bash
# Hash a known token accessor to find it in audit logs
vault audit hash sys/audit-hash/file input="<known_value>"
# Output: hmac-sha256:<hash>
# Search logs for this hash

# Or reverse: find the token by accessor in logs
jq 'select(.auth.accessor == "<accessor>")' /var/log/vault/audit.log
```

### Common Audit Patterns

```bash
# Find who deleted a secret
jq 'select(.request.path == "secret/data/myapp/config" and .request.operation == "delete")' \
  /var/log/vault/audit.log | jq '{time, accessor: .auth.accessor, policies: .auth.policies}'

# Find failed authentication attempts
jq 'select(.request.path | startswith("auth/")) | select(.error != null)' \
  /var/log/vault/audit.log

# Track lease revocations
jq 'select(.request.path | startswith("sys/leases/revoke"))' /var/log/vault/audit.log

# Audit log rotation (via logrotate)
cat > /etc/logrotate.d/vault <<'EOF'
/var/log/vault/audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        /bin/kill -HUP $(cat /var/run/vault.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF
```

---

## Performance Tuning

### Identifying Bottlenecks

```bash
# Enable Prometheus metrics
# vault.hcl:
# telemetry {
#   prometheus_retention_time = "24h"
#   disable_hostname = true
# }

# Query metrics endpoint
curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
  $VAULT_ADDR/v1/sys/metrics?format=prometheus

# Key metrics to monitor:
# vault.core.handle_request (duration) — overall request latency
# vault.barrier.get / vault.barrier.put — storage latency
# vault.expire.num_leases — total active leases
# vault.runtime.alloc_bytes — memory usage
# vault.runtime.num_goroutines — goroutine count
# vault.audit.log_request (duration) — audit write latency
```

### Tuning Vault Configuration

```hcl
# vault.hcl performance tuning options

# Increase max request size (default 32MB)
max_request_size = 67108864  # 64MB

# Tune cache size (default 0 = disabled)
cache_size = 100000

# Listener tuning
listener "tcp" {
  address     = "0.0.0.0:8200"
  # Increase max request duration
  max_request_duration = "90s"

  # TLS settings for performance
  tls_min_version = "tls12"
  tls_prefer_server_cipher_suites = true
}
```

```bash
# Tune secrets engine max TTL and default TTL
vault secrets tune -default-lease-ttl=1h -max-lease-ttl=24h database/

# Tune auth method token TTL
vault auth tune -default-lease-ttl=1h -max-lease-ttl=8h kubernetes/

# Adjust Raft parameters for write-heavy workloads
# storage "raft" {
#   performance_multiplier = 1  # Tighter election timing
#   snapshot_threshold = 16384
# }
```

### Client-Side Optimizations

```bash
# Use connection pooling in client libraries
# Python example:
# import hvac
# client = hvac.Client(url='https://vault:8200', session=requests.Session())

# Use response caching with Vault Agent
# Agent caches auth tokens and secret responses locally

# Batch operations where possible
# Use sys/tools/hash for batch hashing
# Use transit/encrypt for batch encryption:
vault write transit/encrypt/my-key \
  batch_input='[{"plaintext":"cGxhaW4x"},{"plaintext":"cGxhaW4y"}]'

# Use -wrap-ttl for secret delivery instead of multiple reads
```

---

## Disaster Recovery Procedures

### Raft Snapshot Restore

```bash
# Take a snapshot (run regularly!)
vault operator raft snapshot save /backup/vault-$(date +%Y%m%d-%H%M%S).snap

# Verify snapshot
vault operator raft snapshot inspect /backup/vault-latest.snap

# Restore snapshot (run on leader, cluster must be unsealed)
vault operator raft snapshot restore -force /backup/vault-latest.snap
# -force skips the configuration check and restores regardless of
# the current cluster state
```

### Recovering from Data Loss

```bash
# Scenario: Accidental secret deletion (KV v2)
# 1. Check if soft-deleted (within delete_version_after window)
vault kv undelete -versions=1 secret/myapp/config

# 2. If permanently destroyed, restore from snapshot
vault operator raft snapshot restore /backup/vault-latest.snap

# Scenario: Lost all unseal keys
# If auto-unseal configured: Vault auto-unseals on start
# If Shamir and ALL keys lost: DATA IS UNRECOVERABLE
# Preventive: Store key shares in separate secure locations
#   - Hardware security modules
#   - Separate password managers
#   - Physical safes in different locations
```

### Emergency Break-Glass

```bash
# Generate root token (emergency use only)
vault operator generate-root -init
# Distribute nonce to key holders

# Each key holder provides their share
vault operator generate-root -nonce=<nonce> <unseal_key>
# Repeat until threshold met

# Decode the generated token
vault operator generate-root -decode=<encoded_token> -otp=<otp>

# Use root token for emergency operations
VAULT_TOKEN=<root_token> vault policy write emergency-fix emergency.hcl

# ALWAYS revoke root token when done
vault token revoke <root_token>

# Audit: Root token generation is always logged
# Ensure someone reviews the audit log after break-glass events
```

**Root Token Safety Checklist:**
1. Generate root token only when necessary
2. Use it for the minimum required operations
3. Revoke immediately after use
4. Review audit logs for all operations performed
5. Document the incident and operations performed
6. Have at least two people present during the procedure
