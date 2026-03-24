# Vault Troubleshooting Guide

## Table of Contents

- [Seal/Unseal Failures](#sealunseal-failures)
  - [Manual Unseal Failures](#manual-unseal-failures)
  - [Auto-Unseal Failures](#auto-unseal-failures)
  - [Seal Migration Issues](#seal-migration-issues)
- [Token Expiry and Renewal](#token-expiry-and-renewal)
  - [Diagnosing Token Issues](#diagnosing-token-issues)
  - [Token Renewal Strategies](#token-renewal-strategies)
  - [Orphan Token Problems](#orphan-token-problems)
  - [Token Type Confusion](#token-type-confusion)
- [Lease Revocation Storms](#lease-revocation-storms)
  - [Identifying a Revocation Storm](#identifying-a-revocation-storm)
  - [Preventing Revocation Storms](#preventing-revocation-storms)
  - [Recovering from a Revocation Storm](#recovering-from-a-revocation-storm)
- [Storage Backend Performance](#storage-backend-performance)
  - [Raft Performance Tuning](#raft-performance-tuning)
  - [Consul Backend Issues](#consul-backend-issues)
  - [General Storage Diagnostics](#general-storage-diagnostics)
- [Audit Log Flooding](#audit-log-flooding)
  - [Identifying the Cause](#identifying-the-cause)
  - [Mitigating Audit Log Volume](#mitigating-audit-log-volume)
  - [Audit Device Failures](#audit-device-failures)
- [Certificate Rotation Failures](#certificate-rotation-failures)
  - [PKI Engine Issues](#pki-engine-issues)
  - [Vault TLS Certificate Rotation](#vault-tls-certificate-rotation)
  - [Vault Agent Certificate Template Failures](#vault-agent-certificate-template-failures)
- [Kubernetes Auth Mount Issues](#kubernetes-auth-mount-issues)
  - [Configuration Errors](#configuration-errors)
  - [Token Reviewer Problems](#token-reviewer-problems)
  - [Service Account Token Issues](#service-account-token-issues)
  - [Namespace and RBAC Mismatches](#namespace-and-rbac-mismatches)
- [AppRole Secret ID Wrapping](#approle-secret-id-wrapping)
  - [Wrapping Failures](#wrapping-failures)
  - [Unwrapping Issues](#unwrapping-issues)
  - [Secret ID Lifecycle Problems](#secret-id-lifecycle-problems)
- [Raft Cluster Recovery](#raft-cluster-recovery)
  - [Single Node Failure](#single-node-failure)
  - [Quorum Loss](#quorum-loss)
  - [Data Corruption Recovery](#data-corruption-recovery)
  - [Snapshot Operations](#snapshot-operations)
- [Disaster Recovery Procedures](#disaster-recovery-procedures)
  - [DR Replication Failover](#dr-replication-failover)
  - [Full Cluster Rebuild](#full-cluster-rebuild)
  - [Emergency Break-Glass](#emergency-break-glass)
  - [Post-Incident Checklist](#post-incident-checklist)

---

## Seal/Unseal Failures

### Manual Unseal Failures

```bash
# Check current seal status
vault status
# Key fields: Sealed, Unseal Progress, Unseal Nonce, Seal Type

# Error: "unseal key is invalid" or "unseal nonce mismatch"
# Cause: Mixed up key shares from different init ceremonies
# Fix: Reset unseal progress and start over
vault operator unseal -reset

# Error: "cannot unseal — already in progress with different nonce"
vault operator unseal -reset
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>

# Error: "post-unseal setup failed"
# Check server logs for root cause
journalctl -u vault --no-pager -n 100 | grep -i "post-unseal\|error\|fatal"

# Verify storage backend is accessible before unsealing
df -h /opt/vault/data
ls -la /opt/vault/data/

# Consul: verify connectivity
consul members
consul kv get vault/core/seal-config
```

### Auto-Unseal Failures

```bash
# AWS KMS auto-unseal failure
# Error: "error unsealing: failed to decrypt seal key"
aws kms describe-key --key-id <key-id> --query 'KeyMetadata.KeyState'
# Must be "Enabled"

# Check IAM permissions
aws kms encrypt --key-id <key-id> --plaintext "dGVzdA==" --output text 2>&1
# Required: kms:Encrypt, kms:Decrypt, kms:DescribeKey

# Network: ensure Vault can reach KMS endpoint
curl -s https://kms.us-east-1.amazonaws.com/ 2>&1 | head -5

# Azure Key Vault auto-unseal failure
az keyvault key show --vault-name <vault> --name <key> 2>&1
az keyvault network-rule list --name <vault>

# GCP CKMS auto-unseal failure
gcloud kms keys describe <key> --location=<loc> --keyring=<ring> \
  --format='value(primary.state)'
# Must be "ENABLED"

# Transit auto-unseal failure
VAULT_ADDR="https://upstream-vault:8200" VAULT_TOKEN="<transit-token>" \
  vault read transit/keys/autounseal
```

### Seal Migration Issues

```bash
# Error: "cannot migrate seal — vault is not initialized"
# Vault must be initialized with OLD seal before migrating

# Stuck migration: vault started with -migrate but unseal never completes
journalctl -u vault --no-pager -n 50 | grep -i migrate

# Verify old seal config is present with disabled=true
grep -A5 'disabled.*true' /etc/vault.d/vault.hcl

# Restart vault with -migrate flag and provide recovery keys
systemctl stop vault
vault server -config=/etc/vault.d/vault.hcl -migrate &
vault operator unseal -migrate <key>
```

---

## Token Expiry and Renewal

### Diagnosing Token Issues

```bash
# Error: "permission denied" (often a token issue, not a policy issue)
# Step 1: Check if token exists
vault token lookup 2>&1
# "bad token" or "token not found" = expired/revoked

# Step 2: Check token details
vault token lookup -format=json | jq '{
  policies: .data.policies,
  ttl: .data.ttl,
  renewable: .data.renewable,
  expire_time: .data.expire_time,
  type: .data.type,
  orphan: .data.orphan,
  num_uses: .data.num_uses
}'

# Step 3: Check if token's parent was revoked (cascading revocation)
# Step 4: Check audit logs for revocation events
jq 'select(.request.path | startswith("auth/token/revoke"))' \
  /var/log/vault/audit.log | tail -5
```

### Token Renewal Strategies

```bash
# Check remaining TTL before renewing
TTL=$(vault token lookup -format=json | jq -r '.data.ttl')

# Renew with increment
vault token renew -increment=1h

# If renewal fails, re-authenticate
vault write auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID"

# Best practice: renew at 2/3 of TTL (e.g., 1h TTL -> renew at 40m)
# Use Vault Agent for automatic renewal in production
```

### Orphan Token Problems

```bash
# Orphan tokens are NOT revoked when their parent is revoked
# This can lead to token leaks

# Find orphan tokens in audit logs
jq 'select(.auth.orphan == true)' /var/log/vault/audit.log | \
  jq '{accessor: .auth.accessor, policies: .auth.policies, time: .time}'

# List token accessors (requires sudo)
vault list auth/token/accessors

# Revoke specific orphan token by accessor
vault token revoke -accessor <accessor>
```

### Token Type Confusion

```bash
# Batch tokens cannot be renewed or revoked individually
vault token lookup -format=json | jq '.data.type'
# "batch" tokens: large (base64), not stored, not renewable
# "service" tokens: short (s.xxx), stored, renewable

# Error: "batch tokens cannot be renewed"
# Fix: re-authenticate to get a new batch token

# Error: "batch tokens cannot be revoked"
# Batch tokens expire naturally; revoke the parent to cascade

# Force service tokens for a role
vault write auth/approle/role/my-app token_type=service
```

---

## Lease Revocation Storms

### Identifying a Revocation Storm

A revocation storm occurs when a large number of leases expire or are revoked simultaneously, overwhelming Vault and its backend.

```bash
# Symptoms:
# - High CPU/memory on Vault servers
# - Slow or timed-out API responses
# - Storage backend under heavy write load
# - Errors: "context deadline exceeded" in logs

# Check total lease count
vault read -format=json sys/internal/counters/tokens | jq '.data'

# Count leases by prefix
vault list -format=json sys/leases/lookup/database/creds/ 2>/dev/null | \
  jq 'length'

# Monitor Prometheus metrics for lease operations
curl -s "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | \
  grep -E "vault.expire.(num_leases|revoke|renew)"
```

### Preventing Revocation Storms

```bash
# 1. Stagger lease TTLs — use jitter instead of identical TTLs
vault write database/roles/app-role \
  default_ttl=55m max_ttl=24h  # not exactly 1h

# 2. Set lease count quotas (Enterprise)
vault write sys/quotas/lease-count/db-lease-limit \
  path="database/creds/" max_leases=5000

# 3. Use shorter max_ttl to prevent lease accumulation
vault secrets tune -max-lease-ttl=4h database/

# 4. Prefer batch tokens for ephemeral workloads (no lease storage)
vault write auth/kubernetes/role/ephemeral token_type=batch

# 5. Tidy leases periodically
vault write -f sys/leases/tidy
```

### Recovering from a Revocation Storm

```bash
# Emergency: force-revoke all leases under a prefix (skips backend cleanup)
vault lease revoke -prefix -force database/creds/app-role

# Throttle revocations by revoking in batches
for lease_id in $(vault list -format=json sys/leases/lookup/database/creds/app-role \
    | jq -r '.[]' | head -100); do
  vault lease revoke "database/creds/app-role/$lease_id"
  sleep 0.1  # throttle
done

# If Vault is unresponsive, check storage for pressure
vault operator raft autopilot state

# After recovery: review lease configuration
vault read database/roles/app-role | grep -E "ttl|max_ttl"
```

---

## Storage Backend Performance

### Raft Performance Tuning

```bash
# Monitor Raft health
vault operator raft autopilot state -format=json | jq '{
  healthy: .Healthy,
  leader: .Leader
}'

# Key Raft metrics to monitor
curl -s "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | grep -E "raft\." | head -20
# vault.raft.apply — log apply latency (should be <100ms)
# vault.raft.commitTime — commit time (should be <200ms)
# vault.raft.leader.lastContact — follower-to-leader RTT

# Check disk I/O (Raft is I/O sensitive)
iostat -x 5 3
# Solution: use SSDs, dedicated disk for Raft data

# Check Raft log size
du -sh /opt/vault/data/raft/

# Force a Raft snapshot to compact logs
vault operator raft snapshot save /tmp/manual-snapshot.snap
```

Raft tuning parameters (vault.hcl):
```hcl
storage "raft" {
  path                = "/opt/vault/data"
  node_id             = "vault-1"
  performance_multiplier = 1       # tighter election timeout (default: 5)
  snapshot_threshold   = 16384     # snapshots less frequently (default: 8192)
  trailing_logs        = 20000     # keep more logs before snapshot (default: 10000)
}
```

### Consul Backend Issues

```bash
# Check Consul health
consul members
consul operator raft list-peers

# Verify Vault's Consul ACL token
consul acl token read -id <vault-token-id>
# Required permissions:
# key_prefix "vault/" { policy = "write" }
# node_prefix "" { policy = "read" }
# service "vault" { policy = "write" }
# session_prefix "" { policy = "write" }

# Check KV entry count
consul kv get -recurse -keys vault/ | wc -l
```

### General Storage Diagnostics

```bash
# Generate Vault debug bundle
vault debug -duration=5m -targets=metrics,server-status,replication-status,host

# Key metrics
curl -s "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | \
  grep -E "vault\.(barrier|core)\." | head -20
# vault.barrier.get / vault.barrier.put — storage I/O latency
# vault.core.handle_request — overall request duration

# Monitor goroutine count (leak indicator)
curl -s "$VAULT_ADDR/v1/sys/metrics?format=prometheus" | \
  grep "vault.runtime.num_goroutines"
```

---

## Audit Log Flooding

### Identifying the Cause

```bash
# Check audit log growth rate
ls -lh /var/log/vault/audit.log

# Find the top request paths
tail -100000 /var/log/vault/audit.log | \
  jq -r '.request.path // empty' | sort | uniq -c | sort -rn | head -10

# Find the top requesters
tail -100000 /var/log/vault/audit.log | \
  jq -r '.auth.accessor // empty' | sort | uniq -c | sort -rn | head -10

# Common flood sources:
# 1. Vault Agent polling (static_secret_render_interval too low)
# 2. Health check endpoints hitting audit (load balancers)
# 3. Token renewal loops (renewal interval too aggressive)
# 4. Lease renewal storms
# 5. Misconfigured monitoring scraping all paths

# Find requests per second
tail -10000 /var/log/vault/audit.log | \
  jq -r '.time[:19]' | sort | uniq -c | sort -rn | head -5
```

### Mitigating Audit Log Volume

```bash
# 1. Use unauthenticated health check path (not logged)
# Configure LB: GET /v1/sys/health

# 2. Increase Vault Agent polling intervals
# template_config {
#   static_secret_render_interval = "5m"  # not "5s"
# }

# 3. Set up log rotation
cat > /etc/logrotate.d/vault-audit << 'ROTEOF'
/var/log/vault/audit.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize 1G
}
ROTEOF

# 4. Use syslog audit device for centralized management
vault audit enable syslog tag="vault" facility="LOCAL0"
```

### Audit Device Failures

```bash
# CRITICAL: If ALL audit devices fail, Vault BLOCKS all operations
# Error: "no audit backend available to log request"

# Check audit device status
vault audit list -detailed

# If disk full:
df -h /var/log/vault/
# Fix: free space, rotate logs, expand volume

# Emergency: enable a second audit device
vault audit enable -path=emergency-audit file \
  file_path=/tmp/vault-emergency-audit.log

# Disable the failed device
vault audit disable file/
```

---

## Certificate Rotation Failures

### PKI Engine Issues

```bash
# Check CA certificate expiry
vault read -format=json pki/cert/ca | \
  jq -r '.data.certificate' | \
  openssl x509 -noout -dates

# Error: "requested domain not allowed by role"
vault read pki/roles/<role-name> | grep -E "allowed_domains|allow_subdomains"
vault write pki/roles/<role-name> \
  allowed_domains="example.com,newdomain.com" allow_subdomains=true

# Error: "TTL exceeds max"
vault read pki/roles/<role-name> | grep max_ttl
vault secrets tune -max-lease-ttl=87600h pki/

# CRL auto-rebuild
vault write pki/config/crl expiry=72h auto_rebuild=true auto_rebuild_grace_period=12h

# Tidy expired certificates
vault write pki/tidy \
  tidy_cert_store=true \
  tidy_revoked_certs=true \
  safety_buffer=72h
```

### Vault TLS Certificate Rotation

```bash
# Check current certificate expiry
echo | openssl s_client -connect vault.example.com:8200 2>/dev/null | \
  openssl x509 -noout -dates

# Rotate:
# 1. Issue new certificate
vault write pki_int/issue/vault-server \
  common_name="vault.example.com" \
  alt_names="vault-0.vault-internal,vault-1.vault-internal" \
  ttl=8760h

# 2. Replace cert files
cp new-cert.pem /opt/vault/tls/cert.pem
cp new-key.pem /opt/vault/tls/key.pem

# 3. Reload Vault (no restart needed)
vault operator reload

# 4. Verify
echo | openssl s_client -connect vault.example.com:8200 2>/dev/null | \
  openssl x509 -noout -subject -dates
```

### Vault Agent Certificate Template Failures

```bash
# Error: "permission denied" in template rendering
# Check Agent token policies
vault token lookup $(cat /vault/agent/token) | grep policies

# Error: template renders empty file
# Verify the secret path is correct
vault read pki_int/issue/app-certs common_name=app.example.com ttl=24h

# Whitespace in certificate templates — use dash to trim:
# {{- with secret "pki/issue/role" "common_name=app.example.com" -}}
# {{ .Data.certificate }}
# {{- end -}}

# Certificate renewal not triggering
# Ensure command is set to reload the service
# template {
#   command = "nginx -s reload"
#   wait { min = "5s" max = "30s" }
# }
```

---

## Kubernetes Auth Mount Issues

### Configuration Errors

```bash
# Verify auth mount exists
vault auth list | grep kubernetes

# Check configuration
vault read auth/kubernetes/config

# Test connectivity from Vault to K8s API
curl -sk https://kubernetes.default.svc:443/version

# Error: "namespaces not authorized"
vault read auth/kubernetes/role/<role-name>
# Check bound_service_account_namespaces

# Error: "service account name not authorized"
vault read auth/kubernetes/role/<role-name>
# Check bound_service_account_names
```

### Token Reviewer Problems

```bash
# Vault needs token review permissions to validate pod JWTs

# Check if binding exists
kubectl get clusterrolebinding | grep vault

# Create if missing
kubectl create clusterrolebinding vault-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault

# For external Vault, configure with a service account token
TOKEN=$(kubectl create token vault-auth -n vault --duration=8760h)
vault write auth/kubernetes/config \
  kubernetes_host="https://k8s-api.example.com:6443" \
  token_reviewer_jwt="$TOKEN" \
  kubernetes_ca_cert=@/path/to/ca.crt
```

### Service Account Token Issues

```bash
# K8s 1.24+ uses projected service account tokens (time-limited, audience-bound)

# Check pod token contents
kubectl exec -it <pod> -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, sub, aud, exp}'

# Audience mismatch fix
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  issuer="https://kubernetes.default.svc"

# Custom audience in pod spec:
# volumes:
# - name: vault-token
#   projected:
#     sources:
#     - serviceAccountToken:
#         path: vault-token
#         expirationSeconds: 7200
#         audience: vault
```

### Namespace and RBAC Mismatches

```bash
# Update role to allow additional namespaces
vault write auth/kubernetes/role/<role> \
  bound_service_account_names="app-sa" \
  bound_service_account_namespaces="staging,production" \
  policies="app-policy"

# Test login from a pod
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST \
  --data "{\"jwt\":\"$JWT\",\"role\":\"app\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq .
```

---

## AppRole Secret ID Wrapping

### Wrapping Failures

```bash
# Error: "permission denied" when wrapping secret-id
# Policy must allow:
# path "auth/approle/role/my-app/secret-id" {
#   capabilities = ["create", "update"]
# }

# Wrap a secret-id correctly
vault write -wrap-ttl=120s -f auth/approle/role/my-app/secret-id
# Returns: wrapping_token, wrapping_accessor, creation_path

# Verify the wrapping token is valid
vault write sys/wrapping/lookup token=<wrapping_token>
```

### Unwrapping Issues

```bash
# Error: "wrapping token is not valid or does not exist"
# Causes:
# 1. Token already unwrapped (single-use) — possible interception
# 2. Token TTL expired
# 3. Wrong token value

# Check if wrapping token was already used (tamper detection)
vault write sys/wrapping/lookup token=<wrapping_token>
# Error = already consumed or expired

# Proper unwrap flow
WRAPPED=$(vault write -wrap-ttl=120 -f -field=wrapping_token \
  auth/approle/role/my-app/secret-id)
SECRET_ID=$(VAULT_TOKEN="$WRAPPED" vault unwrap -field=secret_id)
```

### Secret ID Lifecycle Problems

```bash
# Error: "invalid secret id" during AppRole login
# Causes: num_uses exhausted, TTL expired, manually revoked

# Check role configuration
vault read auth/approle/role/my-app | grep -E "secret_id_ttl|secret_id_num_uses"

# List active secret ID accessors
vault list auth/approle/role/my-app/secret-id

# Look up specific secret ID
vault write auth/approle/role/my-app/secret-id/lookup secret_id=<secret_id>
# Shows: creation_time, expiration_time, remaining uses

# CIDR binding mismatch
vault read auth/approle/role/my-app | grep cidr
vault write auth/approle/role/my-app \
  secret_id_bound_cidrs="" token_bound_cidrs=""

# Recommended: use-limited, short-TTL, wrapped secret IDs
vault write auth/approle/role/my-app \
  secret_id_ttl=5m secret_id_num_uses=1
```

---

## Raft Cluster Recovery

### Single Node Failure

```bash
# Check cluster state
vault operator raft list-peers

# Remove permanently failed node
vault operator raft remove-peer <node-id>

# Add replacement node (configure retry_join in vault.hcl)
systemctl start vault
vault operator unseal <key>

# Verify
vault operator raft list-peers
vault operator raft autopilot state
```

### Quorum Loss

```bash
# If majority of nodes are lost, cluster cannot elect a leader

# Option 1: Bring enough nodes back to reach majority
for node in vault-1 vault-2; do
  ssh $node 'systemctl start vault'
done

# Option 2: Force new cluster from single node (LAST RESORT)
# 1. Stop ALL vault nodes
# 2. On the node with most recent data, create peers.json:
cat > /opt/vault/data/raft/peers.json << 'PEERS'
[{"id":"vault-1","address":"vault-1:8201","non_voter":false}]
PEERS

# 3. Start only this node
systemctl start vault
vault operator unseal <key>

# 4. Join other nodes one by one
vault operator raft join https://vault-1:8200
```

### Data Corruption Recovery

```bash
# Try to take a snapshot (may fail if corruption is severe)
vault operator raft snapshot save /backup/emergency.snap

# Restore from last known good snapshot
vault operator raft snapshot restore -force /backup/vault-latest.snap

# Verify data integrity
vault status
vault kv list -mount=secret /
vault list sys/leases/lookup/

# If no snapshot: reinitialize (DATA LOSS)
# rm -rf /opt/vault/data/raft/
vault operator init -key-shares=5 -key-threshold=3
```

### Snapshot Operations

```bash
# Manual snapshot
vault operator raft snapshot save /backup/vault-$(date +%Y%m%d-%H%M%S).snap

# Verify snapshot integrity
vault operator raft snapshot inspect /backup/vault-latest.snap

# Restore (run on leader, cluster must be unsealed)
vault operator raft snapshot restore -force /backup/vault-latest.snap

# Automated snapshot schedule (cron example)
# 0 */6 * * * vault operator raft snapshot save /backup/vault-$(date +\%Y\%m\%d-\%H\%M\%S).snap
# 0 2 * * * find /backup -name "vault-*.snap" -mtime +30 -delete
```

---

## Disaster Recovery Procedures

### DR Replication Failover

```bash
# Step 1: Confirm primary is down
curl -s https://vault-primary.example.com:8200/v1/sys/health

# Step 2: Generate DR operation token on secondary
vault operator generate-root -dr-token -init
vault operator generate-root -dr-token \
  -nonce="<nonce>" "<recovery_key>"  # repeat for threshold
DR_TOKEN=$(vault operator generate-root -dr-token \
  -decode="<encoded_token>" -otp="<otp>")

# Step 3: Promote DR secondary
vault write sys/replication/dr/secondary/promote \
  dr_operation_token="$DR_TOKEN"

# Step 4: Update DNS / load balancer
# Step 5: Verify
vault status
vault kv get -mount=secret test/key
```

### Full Cluster Rebuild

```bash
# When all nodes are lost and only snapshots remain:
# 1. Deploy new cluster (3+ nodes)
# 2. Initialize first node
vault operator init -key-shares=5 -key-threshold=3

# 3. Unseal all nodes
# 4. Join remaining nodes
vault operator raft join https://vault-1:8200

# 5. Restore from snapshot
vault operator raft snapshot restore -force /backup/vault-latest.snap

# 6. Verify and re-configure audit, license, replication
```

### Emergency Break-Glass

```bash
# Generate emergency root token
vault operator generate-root -init
vault operator generate-root -nonce=<nonce> <unseal_key>
# Repeat until threshold
vault operator generate-root -decode=<encoded_token> -otp=<otp>

# Use root token for emergency operations ONLY
export VAULT_TOKEN=<root_token>
vault policy write emergency-fix emergency.hcl

# ALWAYS revoke root token when done
vault token revoke "$VAULT_TOKEN"

# Review all root token operations
jq 'select(.auth.policies | index("root"))' /var/log/vault/audit.log
```

### Post-Incident Checklist

1. **Revoke emergency credentials** — root tokens, temporary policies
2. **Review audit logs** — verify no unauthorized access during outage
3. **Rotate affected secrets** — any secret that may have been exposed
4. **Verify replication** — confirm DR/perf secondaries are in sync
5. **Update snapshots** — take a fresh snapshot of the recovered cluster
6. **Test failover** — validate DR procedures still work
7. **Document the incident** — RCA with timeline, actions, improvements
8. **Update runbooks** — incorporate lessons learned
9. **Notify stakeholders** — inform teams of credential rotations needed
10. **Monitor closely** — watch metrics for 24-48 hours post-recovery
