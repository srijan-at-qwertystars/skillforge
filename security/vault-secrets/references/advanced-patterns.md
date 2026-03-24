# Advanced Vault Patterns & Architecture

## Table of Contents

- [The Secret Zero Problem](#the-secret-zero-problem)
  - [Understanding the Challenge](#understanding-the-challenge)
  - [Solution: Trusted Orchestrator Pattern](#solution-trusted-orchestrator-pattern)
  - [Solution: Platform-Native Identity](#solution-platform-native-identity)
  - [Solution: Response Wrapping for Bootstrapping](#solution-response-wrapping-for-bootstrapping)
- [Vault Agent Caching Architecture](#vault-agent-caching-architecture)
  - [Cache Topology](#cache-topology)
  - [Persistent Caching](#persistent-caching)
  - [Cache Eviction and Staleness](#cache-eviction-and-staleness)
  - [Proxy Mode vs Sidecar Mode](#proxy-mode-vs-sidecar-mode)
- [Response Wrapping for Secure Secret Delivery](#response-wrapping-for-secure-secret-delivery)
  - [Wrapping Mechanics](#wrapping-mechanics)
  - [Cubbyhole Response Wrapping](#cubbyhole-response-wrapping)
  - [Tamper Detection](#tamper-detection)
  - [Wrapping in CI/CD Pipelines](#wrapping-in-cicd-pipelines)
- [Control Groups for Approval Workflows](#control-groups-for-approval-workflows)
  - [Architecture and Flow](#architecture-and-flow)
  - [Multi-Factor Control Groups](#multi-factor-control-groups)
  - [Integration with Ticketing Systems](#integration-with-ticketing-systems)
- [Sentinel Policies for Governance](#sentinel-policies-for-governance)
  - [EGP: Endpoint Governing Policies](#egp-endpoint-governing-policies)
  - [RGP: Role Governing Policies](#rgp-role-governing-policies)
  - [Sentinel Imports and Functions](#sentinel-imports-and-functions)
  - [Real-World Governance Examples](#real-world-governance-examples)
- [Performance Replication vs DR Replication](#performance-replication-vs-dr-replication)
  - [Comparison Matrix](#comparison-matrix)
  - [Performance Replication Architecture](#performance-replication-architecture)
  - [DR Replication Architecture](#dr-replication-architecture)
  - [Choosing the Right Strategy](#choosing-the-right-strategy)
  - [Combined Topologies](#combined-topologies)
- [Batch Tokens vs Service Tokens](#batch-tokens-vs-service-tokens)
  - [Token Type Comparison](#token-type-comparison)
  - [When to Use Batch Tokens](#when-to-use-batch-tokens)
  - [When to Use Service Tokens](#when-to-use-service-tokens)
  - [Configuration and Migration](#configuration-and-migration)
- [Entity Aliases and Identity Groups](#entity-aliases-and-identity-groups)
  - [Identity Architecture](#identity-architecture)
  - [Entity Management](#entity-management)
  - [Group Types and Hierarchies](#group-types-and-hierarchies)
  - [Policy Inheritance](#policy-inheritance)
- [OIDC Provider Mode](#oidc-provider-mode)
  - [Vault as an Identity Provider](#vault-as-an-identity-provider)
  - [Client Registration](#client-registration)
  - [Scopes and Claims Customization](#scopes-and-claims-customization)
  - [Integration Examples](#integration-examples)
- [Vault + Terraform Integration Patterns](#vault--terraform-integration-patterns)
  - [Vault Provider for Terraform](#vault-provider-for-terraform)
  - [Managing Vault with Terraform](#managing-vault-with-terraform)
  - [Reading Secrets in Terraform](#reading-secrets-in-terraform)
  - [Terraform Cloud + Vault Dynamic Credentials](#terraform-cloud--vault-dynamic-credentials)
  - [GitOps Vault Configuration](#gitops-vault-configuration)

---

## The Secret Zero Problem

### Understanding the Challenge

The "secret zero" problem is the bootstrapping paradox: to retrieve a secret from Vault, an application needs a credential (token, role-id + secret-id, etc.) — but how does it securely receive that first credential?

```
┌─────────────┐     ┌───────────────┐     ┌───────────────┐
│ Application │──?──│  First Cred   │──?──│    Vault      │
│  (startup)  │     │  (secret zero)│     │   Server      │
└─────────────┘     └───────────────┘     └───────────────┘
     How does the app get this initial credential securely?
```

**Anti-patterns to avoid:**
- Hardcoding tokens in application code or Docker images
- Storing Vault tokens in environment variables across CI/CD pipelines
- Using long-lived root/admin tokens for applications
- Sharing a single AppRole secret-id across multiple instances

### Solution: Trusted Orchestrator Pattern

A trusted orchestrator (e.g., Nomad, Kubernetes, CI/CD platform) with its own Vault identity provisions short-lived, scoped credentials to workloads.

```bash
# Orchestrator retrieves a wrapped secret-id for the app
WRAPPED_TOKEN=$(vault write -wrap-ttl=120s -f \
  auth/approle/role/my-app/secret-id \
  -format=json | jq -r '.wrap_info.token')

# Orchestrator injects ONLY the wrapped token into the app environment
# App unwraps to get the actual secret-id (single use)
SECRET_ID=$(VAULT_TOKEN="$WRAPPED_TOKEN" vault unwrap -field=secret_id)

# App logs in with role-id (baked into image) + secret-id (just unwrapped)
vault write auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID"
```

Key properties:
- Secret-id is wrapped (single-use, time-limited)
- Role-id can be embedded (it's not sensitive alone)
- Orchestrator's token has only `create` on `auth/approle/role/my-app/secret-id`

### Solution: Platform-Native Identity

Use the platform's native identity to authenticate directly — no secret zero needed.

```bash
# Kubernetes: Pod's service account token IS the identity
# No secret-id needed — Vault validates the JWT with the K8s API
vault write auth/kubernetes/login \
  role=my-app \
  jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

# AWS: EC2 instance identity document or IAM role
vault write auth/aws/login \
  role=ec2-app \
  pkcs7="$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/pkcs7)"

# GCP: Service account identity token
vault write auth/gcp/login \
  role=gce-app \
  jwt="$(curl -sH 'Metadata-Flavor: Google' \
    http://metadata/computeMetadata/v1/instance/service-accounts/default/identity?audience=vault/gce-app)"

# Azure: Managed Identity token
vault write auth/azure/login \
  role=azure-app \
  jwt="$(curl -sH 'Metadata: true' \
    'http://169.254.169.254/metadata/identity/oauth2/token?resource=https://management.azure.com/' \
    | jq -r .access_token)"
```

### Solution: Response Wrapping for Bootstrapping

Response wrapping provides single-use, time-limited credential delivery with tamper detection.

```bash
# Administrator wraps the initial credentials
WRAPPED=$(vault token create -policy=app-policy -wrap-ttl=300 \
  -format=json | jq -r '.wrap_info.token')

# Deliver wrapped token via secure channel (config management, init container, etc.)
# App unwraps exactly once — second attempt fails (tamper evidence)
APP_TOKEN=$(VAULT_TOKEN="$WRAPPED" vault unwrap -field=token)

# Verify wrapping token wasn't already unwrapped (tamper detection)
vault write sys/wrapping/lookup token="$WRAPPED"
# If already used: error — indicates potential interception
```

---

## Vault Agent Caching Architecture

### Cache Topology

Vault Agent's cache sits between applications and the Vault server, reducing latency and server load.

```
┌──────────┐   ┌─────────────────────────────┐   ┌──────────┐
│  App 1   │──▶│        Vault Agent          │──▶│  Vault   │
│  App 2   │──▶│  ┌───────┐  ┌────────────┐  │   │  Server  │
│  App 3   │──▶│  │ Cache │  │ Auto-Auth  │  │   │          │
└──────────┘   │  └───────┘  └────────────┘  │   └──────────┘
               │  ┌────────────────────────┐  │
               │  │   Template Engine      │  │
               └──┴────────────────────────┴──┘
```

```hcl
# Vault Agent cache configuration
cache {
  use_auto_auth_token          = true
  use_auto_auth_token_enforce  = true  # reject requests without Agent's token

  # Cache static secrets for performance
  persist "kubernetes" {
    path                 = "/vault/agent-cache"
    keep_after_import    = true
    exit_on_err          = true
    service_account_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  }
}

# Local proxy listener
listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}

# Unix socket for same-host apps (more secure than TCP)
listener "unix" {
  address         = "/vault/agent.sock"
  tls_disable     = true
  socket_mode     = "0660"
  socket_user     = "app"
  socket_group    = "app"
}
```

### Persistent Caching

Persistent caching survives Agent restarts, critical for Kubernetes pod restarts.

```hcl
cache {
  use_auto_auth_token = true
  persist "kubernetes" {
    path              = "/vault/agent-cache"
    keep_after_import = true
    exit_on_err       = false
  }
}
```

```bash
# Verify cache state
ls -la /vault/agent-cache/
# cache.db — BoltDB file with cached tokens and leases

# Monitor cache hits/misses in Agent logs
vault agent -config=agent.hcl -log-level=debug 2>&1 | grep -i cache
```

### Cache Eviction and Staleness

```hcl
# Control how the cache handles token/lease lifecycle
cache {
  use_auto_auth_token = true

  # Cached leases are auto-evicted when they expire
  # Cached tokens are evicted when revoked or expired
  # Token renewal extends cache entry lifetime
}

# Template-level cache control
template {
  source      = "/vault/templates/secret.ctmpl"
  destination = "/vault/secrets/secret.json"

  wait {
    min = "2s"   # minimum wait before re-rendering
    max = "10s"  # maximum wait before re-rendering
  }
}

template_config {
  static_secret_render_interval = "5m"  # poll interval for KV secrets
  max_connections_per_host       = 10
  exit_on_retry_failure          = true
}
```

### Proxy Mode vs Sidecar Mode

**Proxy Mode** — Agent acts as an API proxy; apps talk to Agent instead of Vault:

```hcl
api_proxy {
  use_auto_auth_token = "force"  # inject Agent's token into all proxied requests
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}
```

```bash
# App reads secrets through the Agent proxy (no VAULT_TOKEN needed)
curl -s http://127.0.0.1:8100/v1/secret/data/myapp | jq .
```

**Sidecar Mode** — Agent renders secrets to files; apps read files:

```hcl
template {
  contents    = "{{ with secret \"secret/data/myapp\" }}{{ .Data.data | toJSON }}{{ end }}"
  destination = "/vault/secrets/config.json"
  perms       = 0600
}
```

---

## Response Wrapping for Secure Secret Delivery

### Wrapping Mechanics

Response wrapping stores the actual response in a cubbyhole and returns a single-use wrapping token. The cubbyhole is bound to the wrapping token's identity — no other token can access it.

```bash
# Wrap any Vault response
vault kv get -wrap-ttl=300 -mount=secret myapp/config
# Returns: wrapping_token, creation_time, creation_path, wrapped_accessor

# Wrap during token creation
vault token create -policy=app-policy -wrap-ttl=120
# Returns wrapping token, NOT the actual token

# Wrap during secret-id generation (AppRole bootstrap)
vault write -wrap-ttl=60 -f auth/approle/role/my-app/secret-id
```

### Cubbyhole Response Wrapping

```bash
# Wrapping token metadata (non-destructive lookup)
vault write sys/wrapping/lookup token="s.wrapper123"
# Output: creation_time, creation_path, creation_ttl

# Unwrap (destructive — single use)
VAULT_TOKEN="s.wrapper123" vault unwrap
# Returns the original response; wrapping token is now invalidated

# Rewrap (rotate wrapping token without unwrapping)
vault write sys/wrapping/rewrap token="s.wrapper123"
# Returns new wrapping token; old one invalidated
```

### Tamper Detection

```bash
# If someone intercepts and unwraps the token before the intended recipient:
VAULT_TOKEN="s.wrapper123" vault unwrap
# First unwrap: succeeds, returns secret

VAULT_TOKEN="s.wrapper123" vault unwrap
# Second unwrap: ERROR — "wrapping token is not valid or does not exist"
# This proves interception occurred!

# Proactive check: verify wrapping token is still valid
vault write sys/wrapping/lookup token="s.wrapper123"
# If this fails, the token was already consumed — possible MITM
```

### Wrapping in CI/CD Pipelines

```bash
# CI/CD orchestrator wraps credentials for build jobs
WRAP_TOKEN=$(vault write -wrap-ttl=300 -f -field=wrapping_token \
  auth/approle/role/ci-runner/secret-id)

# Pass wrapped token as a CI/CD variable (safe — single-use, time-limited)
# In the build job:
SECRET_ID=$(VAULT_TOKEN="$WRAP_TOKEN" vault unwrap -field=secret_id)
ROLE_ID=$(cat /etc/vault/role-id)
VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID")

# Use the token for the build, then let it expire
export VAULT_TOKEN
vault kv get -mount=secret ci/deploy-keys
```

---

## Control Groups for Approval Workflows

### Architecture and Flow

Control groups (Enterprise) add approval gates to sensitive operations. When a request matches a control group policy, Vault holds the response and requires one or more authorizers to approve before releasing it.

```
┌──────────┐  1. Request  ┌──────────┐  2. Hold response
│ Requester│──────────────▶│  Vault   │──────┐
└──────────┘               └──────────┘      │
                                              ▼
                               ┌─────────────────────┐
                               │  Pending Approval    │
                               │  (wrapping token     │
                               │   returned to user)  │
                               └─────────────────────┘
                                              │
┌──────────┐  3. Approve   ┌──────────┐      │
│ Approver │──────────────▶│  Vault   │◀─────┘
└──────────┘               └──────────┘
                                │
                                ▼  4. Release
┌──────────┐  5. Unwrap    ┌──────────┐
│ Requester│──────────────▶│  Vault   │──▶ Secret
└──────────┘               └──────────┘
```

```hcl
# Control group policy for production secrets
path "secret/data/production/*" {
  capabilities = ["read"]
  control_group {
    factor "ops-approval" {
      controlled_capabilities = ["read"]
      identity {
        group_names = ["ops-managers"]
        approvals   = 1
      }
    }
    factor "security-approval" {
      controlled_capabilities = ["read"]
      identity {
        group_names = ["security-team"]
        approvals   = 1
      }
    }
    ttl     = "4h"
    max_ttl = "24h"
  }
}
```

### Multi-Factor Control Groups

```bash
# Step 1: Developer requests a production secret
vault kv get -mount=secret production/db-creds
# Output: wrapping_token (NOT the secret)
# Accessor: abc123def456

# Step 2: Ops manager approves
vault write sys/control-group/authorize accessor=abc123def456
# "Authorized!"

# Step 3: Security team member approves
vault write sys/control-group/authorize accessor=abc123def456
# "Authorized!"

# Step 4: Developer unwraps to get the secret
vault unwrap <wrapping_token>
# Output: the actual secret data

# Check control group status
vault write sys/control-group/request accessor=abc123def456
# Shows: approved/pending status for each factor
```

### Integration with Ticketing Systems

```python
# Webhook handler for Slack/PagerDuty/Jira integration
# When a control group request is created, notify approvers
# When approved, update the ticket

import hvac
import requests

def handle_control_group_request(accessor, requester, path):
    # Create Jira ticket
    ticket = create_jira_ticket(
        summary=f"Vault Access Request: {path}",
        description=f"User {requester} requests access to {path}",
        assignee="ops-managers-group"
    )

    # Notify via Slack
    slack_notify(
        channel="#vault-approvals",
        message=f"Access request for `{path}` by {requester}. "
                f"Approve: `vault write sys/control-group/authorize accessor={accessor}`"
    )
```

---

## Sentinel Policies for Governance

### EGP: Endpoint Governing Policies

EGPs are attached to API paths and evaluated on every matching request.

```python
# restrict-kv-size.sentinel — Limit secret value sizes
import "strings"

max_size = 10240  # 10KB

main = rule {
  all request.data as key, value {
    length(value else "") <= max_size
  }
}
```

```python
# require-labels.sentinel — Require custom_metadata labels on KV writes
main = rule when request.operation in ["create", "update"] {
  "owner" in keys(request.data.options.custom_metadata else {}) and
  "team" in keys(request.data.options.custom_metadata else {})
}
```

```bash
# Apply EGP to all KV writes
vault write sys/policies/egp/require-labels \
  policy="$(cat require-labels.sentinel)" \
  paths='["secret/data/*"]' \
  enforcement_level="hard-mandatory"
```

### RGP: Role Governing Policies

RGPs are attached to tokens/identities and travel with the request.

```python
# business-hours-only.sentinel
import "time"

business_hours = rule {
  time.now.hour >= 9 and time.now.hour < 17
}

weekday = rule {
  time.now.weekday > 0 and time.now.weekday < 6
}

main = rule {
  business_hours and weekday
}
```

```python
# geo-restrict.sentinel — Restrict access by source IP CIDR
import "sockaddr"

allowed_cidrs = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]

main = rule {
  any allowed_cidrs as cidr {
    sockaddr.is_contained(request.connection.remote_addr, cidr)
  }
}
```

### Sentinel Imports and Functions

| Import | Purpose |
|--------|---------|
| `time` | Time-based policy decisions |
| `sockaddr` | IP/CIDR-based restrictions |
| `strings` | String manipulation |
| `mfa` | Multi-factor authentication checks |
| `identity` | Entity/group metadata access |

### Real-World Governance Examples

```python
# mandatory-encryption.sentinel — Require transit encryption for sensitive paths
import "strings"

sensitive_prefixes = ["secret/data/pci/", "secret/data/phi/", "secret/data/pii/"]

is_sensitive = rule {
  any sensitive_prefixes as prefix {
    strings.has_prefix(request.path, prefix)
  }
}

main = rule when is_sensitive {
  all request.data as key, value {
    key == "options" or strings.has_prefix(value else "", "vault:v")
  }
}
```

```python
# max-ttl-enforcement.sentinel — Cap TTL on dynamic credentials
import "strings"

max_ttl_seconds = 86400  # 24 hours

main = rule when strings.has_prefix(request.path, "database/") {
  (request.data.ttl else 0) <= max_ttl_seconds and
  (request.data.max_ttl else 0) <= max_ttl_seconds
}
```

---

## Performance Replication vs DR Replication

### Comparison Matrix

| Feature | Performance Replication | DR Replication |
|---------|----------------------|----------------|
| Serves read requests | Yes | No (standby only) |
| Serves write requests | Forwards to primary | No |
| Local token generation | Yes (batch tokens) | No |
| Independent seal | Yes | Uses primary's seal |
| Separate audit devices | Yes | No |
| Filtered replication | Yes | No (full replica) |
| Promotion | Manual, non-destructive | Manual, requires DR token |
| Use case | Geo-distributed reads | Disaster recovery |
| License | Enterprise | Enterprise |

### Performance Replication Architecture

```
                    ┌────────────────────────┐
                    │   Primary Cluster      │
                    │   (us-east-1)          │
                    │   Read + Write         │
                    └───┬──────────┬─────────┘
            repl stream │          │ repl stream
                        ▼          ▼
    ┌───────────────────────┐  ┌───────────────────────┐
    │ Perf Secondary        │  │ Perf Secondary        │
    │ (eu-west-1)           │  │ (ap-southeast-1)      │
    │ Read + Forward Write  │  │ Read + Forward Write  │
    └───────────────────────┘  └───────────────────────┘
```

```bash
# Setup performance replication
# Primary:
vault write -f sys/replication/performance/primary/enable
vault write sys/replication/performance/primary/secondary-token \
  id="eu-secondary"

# Secondary (fresh install):
vault write sys/replication/performance/secondary/enable \
  token="<activation_token>"

# Filtered replication (only specific mounts)
vault write sys/replication/performance/primary/secondary-token \
  id="eu-secondary" \
  secondary_filter='{"mode":"allow","paths":["secret/","pki/"]}'
```

### DR Replication Architecture

```
    ┌────────────────────────┐
    │   Primary Cluster      │
    │   (us-east-1)          │
    │   Active               │
    └───────────┬────────────┘
                │ repl stream (full)
                ▼
    ┌────────────────────────┐
    │   DR Secondary         │
    │   (us-west-2)          │
    │   Hot Standby          │
    │   (no client traffic)  │
    └────────────────────────┘
```

```bash
# DR failover procedure
# 1. Generate DR operation token
vault operator generate-root -dr-token -init
vault operator generate-root -dr-token \
  -nonce="<nonce>" "<recovery_key>"  # repeat for threshold

# 2. Promote DR secondary
vault write sys/replication/dr/secondary/promote \
  dr_operation_token="<dr_token>"

# 3. Update DNS/load balancer to point to new primary
# 4. Demote old primary when recovered
vault write -f sys/replication/dr/primary/demote
```

### Choosing the Right Strategy

- **Performance replication** when: users span multiple regions, read latency matters, you want regional autonomy for reads
- **DR replication** when: you need RPO/RTO guarantees, regulatory compliance requires a standby site, protecting against region-wide outages
- **Both** when: you need global reads AND disaster recovery (common in enterprise)

### Combined Topologies

```
                 ┌─────────────────┐
                 │  Primary (East) │
                 └──┬──────────┬───┘
         perf repl  │          │  DR repl
                    ▼          ▼
    ┌──────────────────┐  ┌──────────────────┐
    │ Perf Sec (Europe)│  │ DR Sec (West)    │
    │ Serves reads     │  │ Hot standby      │
    └──────────────────┘  └──────────────────┘
```

---

## Batch Tokens vs Service Tokens

### Token Type Comparison

| Feature | Service Tokens | Batch Tokens |
|---------|---------------|--------------|
| Stored in storage | Yes | No (self-contained) |
| Renewable | Yes | No |
| Revocable individually | Yes | No (parent revocation cascades) |
| Can create child tokens | Yes | No |
| Has accessor | Yes | No |
| Performance cost | Higher (storage I/O) | Lower (no storage) |
| Size | Short (s.xxxx) | Large (JWT-like, ~4KB) |
| Replication | Local to cluster | Usable across perf replicas |
| Use-limit support | Yes | No |
| Cubbyhole access | Yes | No |

### When to Use Batch Tokens

```bash
# High-throughput services needing short-lived tokens
vault token create -type=batch -policy=app-policy -ttl=5m

# Performance replication: batch tokens work on secondaries
# (service tokens created on primary can't auth on secondaries)

# Ephemeral workloads (serverless, CI/CD jobs)
vault write -f auth/approle/role/lambda-function \
  token_type=batch \
  token_ttl=15m \
  token_policies="lambda-policy"

# Reduce storage pressure during high concurrency
vault write auth/kubernetes/role/high-throughput \
  token_type=batch \
  bound_service_account_names=worker \
  bound_service_account_namespaces=production \
  token_ttl=1h policies=worker-policy
```

### When to Use Service Tokens

```bash
# Long-running services that need token renewal
vault token create -type=service -policy=app-policy \
  -ttl=1h -renewable

# Tokens that need revocation tracking
vault token create -type=service -policy=admin-policy

# Applications using cubbyhole for temporary secret storage
vault write cubbyhole/temp-config key=value

# When you need use-limited tokens
vault token create -type=service -use-limit=5 -policy=setup-policy
```

### Configuration and Migration

```bash
# Set default token type for an auth method
vault write auth/approle/role/my-app token_type=batch
vault auth tune -default-lease-ttl=1h -token-type=batch approle/

# Check token type
vault token lookup -format=json | jq -r '.data.type'
# "service" or "batch"

# Monitor token counts (service tokens only — batch aren't tracked)
vault read sys/internal/counters/tokens
```

---

## Entity Aliases and Identity Groups

### Identity Architecture

Vault's identity system maps disparate auth method identities to a single canonical entity.

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  LDAP Login │─┐   │  K8s Login  │─┐   │  OIDC Login  │─┐
│  "asmith"   │ │   │  "app-sa"   │ │   │  "a@co.com"  │ │
└─────────────┘ │   └─────────────┘ │   └──────────────┘ │
                ▼                   ▼                     ▼
         ┌──────────────────────────────────────────────────┐
         │              Entity: "alice-smith"               │
         │  Metadata: team=platform, env=production         │
         │  Policies: [user-workspace, team-platform]       │
         │                                                  │
         │  Aliases:                                        │
         │    - ldap/asmith                                 │
         │    - kubernetes/app-sa                           │
         │    - oidc/a@co.com                               │
         └──────────────────────────────────────────────────┘
                          │ member_of
                          ▼
         ┌──────────────────────────────────────────────────┐
         │              Group: "platform-team"              │
         │  Policies: [platform-secrets, transit-encrypt]   │
         └──────────────────────────────────────────────────┘
```

### Entity Management

```bash
# Create an entity
vault write identity/entity name="alice-smith" \
  policies="user-workspace" \
  metadata=team="platform" metadata=env="production"

# Get entity ID
ENTITY_ID=$(vault read -field=id identity/entity/name/alice-smith)

# Create aliases for each auth method
LDAP_ACCESSOR=$(vault auth list -format=json | jq -r '.["ldap/"].accessor')
vault write identity/entity-alias \
  name="asmith" canonical_id="$ENTITY_ID" mount_accessor="$LDAP_ACCESSOR"

K8S_ACCESSOR=$(vault auth list -format=json | jq -r '.["kubernetes/"].accessor')
vault write identity/entity-alias \
  name="app-sa" canonical_id="$ENTITY_ID" mount_accessor="$K8S_ACCESSOR"

# Now alice gets the same policies regardless of auth method
```

### Group Types and Hierarchies

```bash
# Internal group — manually managed membership
vault write identity/group name="platform-team" \
  policies="platform-secrets" \
  member_entity_ids="$ENTITY_ID_1,$ENTITY_ID_2"

# External group — auto-populated from auth method groups (e.g., LDAP)
vault write identity/group name="ldap-engineers" type="external" \
  policies="engineering-secrets"
GROUP_ID=$(vault read -field=id identity/group/name/ldap-engineers)
vault write identity/group-alias \
  name="cn=engineers,ou=groups,dc=example,dc=com" \
  mount_accessor="$LDAP_ACCESSOR" canonical_id="$GROUP_ID"

# Nested groups (group hierarchy)
PARENT_ID=$(vault read -field=id identity/group/name/engineering)
vault write identity/group name="platform-team" \
  member_group_ids="$PARENT_ID" \
  policies="platform-specific"
```

### Policy Inheritance

Entities inherit policies from:
1. Direct entity policies
2. All groups the entity belongs to (internal)
3. All groups resolved from auth method groups (external)
4. Parent groups in the hierarchy

```hcl
# Templated policy using entity metadata
path "secret/data/teams/{{identity.entity.metadata.team}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Group-scoped policy
path "secret/data/groups/{{identity.groups.names.platform-team.id}}/*" {
  capabilities = ["read", "list"]
}
```

---

## OIDC Provider Mode

### Vault as an Identity Provider

Vault can act as a full OIDC provider, allowing downstream applications to authenticate users through Vault's identity system.

```bash
# Configure the OIDC provider
vault write identity/oidc/config \
  issuer="https://vault.example.com:8200"

# Verify discovery endpoint
curl -s https://vault.example.com:8200/v1/identity/oidc/.well-known/openid-configuration | jq .
```

### Client Registration

```bash
# Create a signing key
vault write identity/oidc/key/app-key \
  rotation_period=24h \
  verification_ttl=24h \
  algorithm=RS256

# Create a named key/role for claims template
vault write identity/oidc/role/app-role \
  key="app-key" \
  ttl=1h \
  template='{"username":{{identity.entity.name}},"email":{{identity.entity.metadata.email}},"groups":{{identity.entity.groups.names}}}'

# Create an OIDC client (application registration)
vault write identity/oidc/client/grafana \
  redirect_uris="https://grafana.example.com/login/generic_oauth" \
  assignments="allow_all" \
  key="app-key" \
  id_token_ttl=1h \
  access_token_ttl=30m

# Create a provider (combines key + client + scopes)
vault write identity/oidc/provider/default \
  allowed_client_ids="$(vault read -field=client_id identity/oidc/client/grafana)" \
  scopes_supported="openid,profile,email,groups"
```

### Scopes and Claims Customization

```bash
# Define custom scopes with claim templates
vault write identity/oidc/scope/profile \
  template='{"name":{{identity.entity.name}},"created":{{identity.entity.creation_time}}}'

vault write identity/oidc/scope/email \
  template='{"email":{{identity.entity.metadata.email}}}'

vault write identity/oidc/scope/groups \
  template='{"groups":{{identity.entity.groups.names}}}'
```

### Integration Examples

```ini
# Grafana configuration (grafana.ini)
[auth.generic_oauth]
enabled = true
name = Vault
client_id = <vault_client_id>
client_secret = <vault_client_secret>
auth_url = https://vault.example.com:8200/ui/vault/identity/oidc/provider/default/authorize
token_url = https://vault.example.com:8200/v1/identity/oidc/provider/default/token
api_url = https://vault.example.com:8200/v1/identity/oidc/provider/default/userinfo
scopes = openid profile email groups
```

---

## Vault + Terraform Integration Patterns

### Vault Provider for Terraform

```hcl
# terraform configuration
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "vault" {
  address = "https://vault.example.com:8200"
  # Auth via VAULT_TOKEN env var, or:
  auth_login {
    path = "auth/approle/login"
    parameters = {
      role_id   = var.vault_role_id
      secret_id = var.vault_secret_id
    }
  }
}
```

### Managing Vault with Terraform

```hcl
# Configure secrets engines
resource "vault_mount" "kv" {
  path        = "secret"
  type        = "kv-v2"
  description = "Application secrets"
}

resource "vault_mount" "transit" {
  path = "transit"
  type = "transit"
}

resource "vault_transit_secret_backend_key" "app_key" {
  backend          = vault_mount.transit.path
  name             = "app-encryption-key"
  type             = "aes256-gcm96"
  deletion_allowed = false
}

# Configure auth methods
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = "https://kubernetes.default.svc:443"
}

resource "vault_kubernetes_auth_backend_role" "app" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "webapp"
  bound_service_account_names      = ["webapp-sa"]
  bound_service_account_namespaces = ["production"]
  token_policies                   = ["webapp-policy"]
  token_ttl                        = 3600
}

# Policies as code
resource "vault_policy" "webapp" {
  name   = "webapp-policy"
  policy = file("${path.module}/policies/webapp.hcl")
}

# KV secrets
resource "vault_kv_secret_v2" "app_config" {
  mount = vault_mount.kv.path
  name  = "webapp/config"
  data_json = jsonencode({
    log_level   = "info"
    environment = "production"
  })
}
```

### Reading Secrets in Terraform

```hcl
# Read a KV secret
data "vault_kv_secret_v2" "db_config" {
  mount = "secret"
  name  = "webapp/database"
}

# Use in other resources
resource "kubernetes_secret" "db" {
  metadata { name = "db-credentials" }
  data = {
    username = data.vault_kv_secret_v2.db_config.data["username"]
    password = data.vault_kv_secret_v2.db_config.data["password"]
  }
}

# Generate dynamic database credentials
data "vault_generic_secret" "db_creds" {
  path = "database/creds/terraform-role"
}

# Use dynamic credentials for provider configuration
provider "postgresql" {
  host     = "db.example.com"
  username = data.vault_generic_secret.db_creds.data["username"]
  password = data.vault_generic_secret.db_creds.data["password"]
}

# Generate PKI certificates
data "vault_pki_secret_backend_cert" "app" {
  backend     = "pki"
  name        = "web-server"
  common_name = "app.example.com"
  ttl         = "720h"
}
```

### Terraform Cloud + Vault Dynamic Credentials

```hcl
# Vault side: configure JWT auth for Terraform Cloud
resource "vault_jwt_auth_backend" "tfc" {
  path               = "jwt-tfc"
  oidc_discovery_url = "https://app.terraform.io"
  bound_issuer       = "https://app.terraform.io"
}

resource "vault_jwt_auth_backend_role" "tfc_role" {
  backend        = vault_jwt_auth_backend.tfc.path
  role_name      = "tfc-workspace-role"
  token_policies = ["tfc-policy"]
  bound_audiences = ["vault.workload.identity"]
  bound_claims = {
    sub = "organization:my-org:project:my-project:workspace:my-workspace:run_phase:*"
  }
  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
  token_ttl  = 1200
}
```

### GitOps Vault Configuration

```yaml
# Directory structure for Vault-as-Code
# vault-config/
# ├── auth/
# │   ├── kubernetes.tf
# │   ├── oidc.tf
# │   └── approle.tf
# ├── secrets-engines/
# │   ├── kv.tf
# │   ├── transit.tf
# │   ├── pki.tf
# │   └── database.tf
# ├── policies/
# │   ├── admin.hcl
# │   ├── webapp.hcl
# │   ├── ci-cd.hcl
# │   └── policies.tf
# ├── namespaces/
# │   └── namespaces.tf
# └── main.tf
```

```hcl
# CI/CD pipeline for Vault config changes
# .github/workflows/vault-config.yml
# On PR: terraform plan (review changes)
# On merge to main: terraform apply (deploy)

# main.tf — iterate over policy files
locals {
  policy_files = fileset("${path.module}/policies", "*.hcl")
}

resource "vault_policy" "policies" {
  for_each = local.policy_files
  name     = trimsuffix(each.value, ".hcl")
  policy   = file("${path.module}/policies/${each.value}")
}
```
