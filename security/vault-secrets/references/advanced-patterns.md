# Advanced Vault Patterns & Enterprise Features

## Table of Contents

- [Templated Policies](#templated-policies)
- [Sentinel Policies (EGP/RGP)](#sentinel-policies-egprgp)
  - [Endpoint Governing Policies (EGP)](#endpoint-governing-policies-egp)
  - [Role Governing Policies (RGP)](#role-governing-policies-rgp)
- [Performance Replication](#performance-replication)
  - [Architecture](#architecture)
  - [Setup](#setup)
  - [Filtered Replication](#filtered-replication)
- [Disaster Recovery Replication](#disaster-recovery-replication)
  - [Setup](#dr-setup)
  - [Failover Procedures](#failover-procedures)
- [Seal Migration](#seal-migration)
  - [Shamir to Auto-Unseal](#shamir-to-auto-unseal)
  - [Auto-Unseal to Auto-Unseal](#auto-unseal-to-auto-unseal)
- [Auto-Unseal Configurations](#auto-unseal-configurations)
  - [AWS KMS](#aws-kms)
  - [Azure Key Vault](#azure-key-vault)
  - [GCP Cloud KMS](#gcp-cloud-kms)
  - [Transit Auto-Unseal](#transit-auto-unseal)
- [Identity Secrets Engine](#identity-secrets-engine)
  - [Entities and Aliases](#entities-and-aliases)
  - [Groups](#groups)
  - [OIDC Identity Provider](#oidc-identity-provider)
- [Transform Secrets Engine](#transform-secrets-engine)
  - [FPE Tokenization](#fpe-tokenization)
  - [Masking](#masking)
  - [Tokenization](#tokenization)
- [KMIP Secrets Engine](#kmip-secrets-engine)
- [Multi-Tenancy with Namespaces](#multi-tenancy-with-namespaces)
  - [Namespace Hierarchy](#namespace-hierarchy)
  - [Cross-Namespace Policies](#cross-namespace-policies)
  - [Namespace Quotas](#namespace-quotas)
- [Advanced Lease Management](#advanced-lease-management)
- [Response Wrapping Patterns](#response-wrapping-patterns)
- [Control Groups](#control-groups)
- [Performance Standby Nodes](#performance-standby-nodes)

---

## Templated Policies

Templated policies use identity information to create dynamic, per-entity access rules without writing individual policies.

### Available Template Parameters

| Parameter | Description |
|-----------|-------------|
| `{{identity.entity.id}}` | Entity UUID |
| `{{identity.entity.name}}` | Entity name |
| `{{identity.entity.aliases.<mount_accessor>.name}}` | Alias name for a specific auth mount |
| `{{identity.entity.metadata.<key>}}` | Entity metadata value |
| `{{identity.groups.ids.<group_id>.name}}` | Group name by ID |
| `{{identity.groups.names.<group_name>.id}}` | Group ID by name |

### Per-User Secret Paths

```hcl
# Each user gets their own secret space
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Team-scoped access using group membership
path "secret/data/teams/{{identity.groups.names.engineering.id}}/*" {
  capabilities = ["read", "list"]
}

# Auth-method-specific paths (e.g., LDAP username)
path "secret/data/ldap-users/{{identity.entity.aliases.auth_ldap_a1b2c3.name}}/*" {
  capabilities = ["create", "read", "update", "delete"]
}
```

### Metadata-Driven Policies

```hcl
# Use entity metadata for environment-scoped access
path "secret/data/{{identity.entity.metadata.environment}}/*" {
  capabilities = ["read", "list"]
}

# Department-scoped database credentials
path "database/creds/{{identity.entity.metadata.department}}-*" {
  capabilities = ["read"]
}
```

### Applying Templated Policies

```bash
vault policy write user-workspace - <<'EOF'
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/users/{{identity.entity.name}}/*" {
  capabilities = ["list", "read", "delete"]
}
EOF

# Set entity metadata
vault write identity/entity/name/alice metadata=environment=production metadata=department=eng
```

---

## Sentinel Policies (EGP/RGP)

Sentinel provides fine-grained, logic-based policy enforcement (Enterprise only). Written in the Sentinel language.

### Endpoint Governing Policies (EGP)

EGPs are attached to API paths and run on every matching request.

```python
# cidr-check.sentinel — Restrict KV writes to internal IPs
import "sockaddr"
import "strings"

# Only allow writes from corporate network
precond = rule {
  request.operation in ["create", "update"]
}

main = rule when precond {
  sockaddr.is_contained(request.connection.remote_addr, "10.0.0.0/8")
}
```

```bash
vault write sys/policies/egp/cidr-check \
  policy="$(cat cidr-check.sentinel)" \
  paths='["secret/data/*"]' \
  enforcement_level="hard-mandatory"
```

### Enforcement Levels

| Level | Behavior |
|-------|----------|
| `advisory` | Logged but not enforced |
| `soft-mandatory` | Can be overridden with `sudo` capability |
| `hard-mandatory` | Always enforced, no override |

### Role Governing Policies (RGP)

RGPs are attached to tokens/identities and travel with the token.

```python
# business-hours.sentinel — Only allow access during business hours
import "time"

workdays = rule {
  time.now.weekday > 0 and time.now.weekday < 6
}

workhours = rule {
  time.now.hour >= 8 and time.now.hour < 18
}

main = rule {
  workdays and workhours
}
```

```bash
vault write sys/policies/rgp/business-hours \
  policy="$(cat business-hours.sentinel)" \
  enforcement_level="soft-mandatory"

# Attach to a token
vault token create -policy="business-hours" -policy="app-policy"
```

### Advanced Sentinel Examples

```python
# require-metadata.sentinel — Require specific KV metadata on writes
import "strings"

main = rule {
  # Require "owner" key in custom_metadata for all KV writes
  request.operation in ["create", "update"] implies
    "owner" in keys(request.data.custom_metadata else {})
}

# mfa-for-delete.sentinel — Require MFA for destructive operations
import "mfa"

main = rule {
  request.operation in ["delete"] implies
    mfa.methods.totp.valid
}
```

---

## Performance Replication

Performance replication creates read-only replicas in different regions to reduce latency. Write requests are forwarded to the primary cluster.

### Architecture

```
Primary Cluster (us-east-1)         Performance Secondary (eu-west-1)
┌─────────────────────┐              ┌─────────────────────┐
│  Leader + Standbys  │──repl stream─▶│  Leader + Standbys  │
│  (read + write)     │              │  (read + fwd write) │
└─────────────────────┘              └─────────────────────┘
                                     Performance Secondary (ap-southeast-1)
                                     ┌─────────────────────┐
                      ──repl stream─▶│  Leader + Standbys  │
                                     │  (read + fwd write) │
                                     └─────────────────────┘
```

### Setup

```bash
# On primary cluster
vault write -f sys/replication/performance/primary/enable

# Generate secondary activation token
vault write sys/replication/performance/primary/secondary-token id="eu-cluster"
# Output: wrapping_token (use within TTL)

# On secondary cluster (must be freshly initialized, not unsealed)
vault write sys/replication/performance/secondary/enable token="<wrapping_token>"
```

### Filtered Replication

Limit which paths replicate to specific secondaries:

```bash
# Only replicate specific mounts to a secondary
vault write sys/replication/performance/primary/secondary-token \
  id="eu-cluster" \
  secondary_filter='{"mode":"allow","paths":["secret/","transit/"]}'

# Update filter on existing secondary
vault write sys/replication/performance/primary/mount-filter/eu-cluster \
  mode="allow" paths="secret/,transit/"
```

### Performance Standbys

Enterprise feature allowing standbys to serve reads (not just forward):

```hcl
# vault.hcl
performance_standby_enabled = true

# Clients can target standbys directly for reads
# X-Vault-Forward header forces forwarding to active node
```

---

## Disaster Recovery Replication

DR replication creates a hot standby cluster for failover. DR secondaries do NOT serve requests until promoted.

### DR Setup

```bash
# On primary
vault write -f sys/replication/dr/primary/enable

# Generate DR secondary token
vault write sys/replication/dr/primary/secondary-token id="dr-cluster"

# On DR secondary
vault write sys/replication/dr/secondary/enable token="<wrapping_token>"
```

### Failover Procedures

```bash
# 1. Generate DR operation token (requires unseal/recovery keys)
vault operator generate-root -dr-token -init
vault operator generate-root -dr-token \
  -nonce="<nonce>" "<unseal_key_share>"
# Repeat for threshold shares, decode the OTP-encoded token

# 2. Promote DR secondary to primary
vault write sys/replication/dr/secondary/promote dr_operation_token="<token>"

# 3. Update DNS/LB to point to new primary

# 4. After old primary recovers, demote it
vault write -f sys/replication/dr/primary/demote

# 5. Re-add as secondary
vault write sys/replication/dr/secondary/enable token="<new_activation_token>"
```

### Batch DR Token

For automation, generate a batch DR operation token:

```bash
vault write sys/replication/dr/primary/batch-token \
  dr_operation_token="<token>" \
  token_ttl=300
```

---

## Seal Migration

### Shamir to Auto-Unseal

```hcl
# vault.hcl — Add seal stanza, set disabled=true on old Shamir
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key"
}
```

```bash
# Step 1: Stop Vault
systemctl stop vault

# Step 2: Update config with new seal stanza
# Step 3: Start Vault with -migrate flag
vault server -config=/etc/vault.d/vault.hcl -migrate

# Step 4: Provide Shamir unseal keys when prompted
vault operator unseal -migrate <key1>
vault operator unseal -migrate <key2>
vault operator unseal -migrate <key3>
# Migration completes, Vault now uses AWS KMS for unsealing
```

### Auto-Unseal to Auto-Unseal

```hcl
# vault.hcl — New seal with disabled old seal
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key-NEW"
}

# Keep old seal with disabled = true
seal "awskms" {
  name       = "old-kms"
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key-OLD"
  disabled   = true
}
```

```bash
vault server -config=/etc/vault.d/vault.hcl -migrate
# Vault automatically migrates from old KMS key to new
```

---

## Auto-Unseal Configurations

### AWS KMS

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key"
  # Optional: endpoint, access_key, secret_key (prefer IAM roles)
}
```

Required IAM permissions:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
    "Resource": "arn:aws:kms:us-east-1:ACCOUNT:key/KEY_ID"
  }]
}
```

### Azure Key Vault

```hcl
seal "azurekeyvault" {
  tenant_id  = "aaaaa-bbbb-cccc-dddd"
  vault_name = "vault-unseal-keyvault"
  key_name   = "vault-unseal-key"
  # Auth: AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET env vars
  # or Managed Identity
}
```

### GCP Cloud KMS

```hcl
seal "gcpckms" {
  project    = "my-project"
  region     = "global"
  key_ring   = "vault-keyring"
  crypto_key = "vault-unseal-key"
  # Auth: GOOGLE_APPLICATION_CREDENTIALS or workload identity
}
```

### Transit Auto-Unseal

Use another Vault cluster's Transit engine to unseal:

```hcl
seal "transit" {
  address         = "https://vault-primary.example.com:8200"
  token           = "s.unsealer-token"
  disable_renewal = false
  key_name        = "autounseal"
  mount_path      = "transit/"
  # TLS config
  tls_ca_cert = "/etc/vault.d/ca.pem"
}
```

---

## Identity Secrets Engine

The identity system is Vault's built-in user management. It creates a canonical entity for each user regardless of auth method.

### Entities and Aliases

```bash
# Create an entity
vault write identity/entity name="alice" policies="user-policy" \
  metadata=team="engineering" metadata=env="production"

# Create an alias linking auth method identity to entity
ENTITY_ID=$(vault read -field=id identity/entity/name/alice)
ACCESSOR=$(vault auth list -format=json | jq -r '.["ldap/"].accessor')

vault write identity/entity-alias \
  name="alice.smith" canonical_id="$ENTITY_ID" mount_accessor="$ACCESSOR"
```

### Groups

```bash
# Internal group (manually managed membership)
vault write identity/group name="engineering" \
  policies="eng-policy" \
  member_entity_ids="$ENTITY_ID_1,$ENTITY_ID_2"

# External group (auto-populated from auth method groups)
vault write identity/group name="ldap-engineering" type="external" \
  policies="eng-policy"

GROUP_ID=$(vault read -field=id identity/group/name/ldap-engineering)
vault write identity/group-alias name="cn=engineering,ou=groups,dc=example,dc=com" \
  mount_accessor="$LDAP_ACCESSOR" canonical_id="$GROUP_ID"
```

### OIDC Identity Provider

Vault can act as an OIDC provider for downstream applications:

```bash
# Enable OIDC provider
vault write identity/oidc/config issuer="https://vault.example.com:8200"

# Create a key
vault write identity/oidc/key/app-key \
  rotation_period=24h verification_ttl=24h

# Create a role (defines the OIDC claims)
vault write identity/oidc/role/app-role key="app-key" \
  template='{"username":{{identity.entity.name}},"groups":{{identity.entity.groups.names}}}'

# Create client application
vault write identity/oidc/client/my-app \
  redirect_uris="https://app.example.com/callback" \
  assignments="allow_all" key="app-key"

# Discovery endpoint: $VAULT_ADDR/v1/identity/oidc/.well-known/openid-configuration
```

---

## Transform Secrets Engine

Enterprise engine for tokenization, format-preserving encryption (FPE), and masking.

### FPE Tokenization

```bash
vault secrets enable transform

# Create an alphabet (or use built-in: builtin/numeric, builtin/alphanumericlower)
vault write transform/alphabet/credit-card-chars charset="0123456789"

# Create a template
vault write transform/template/credit-card-tmpl \
  type=regex pattern='(\d{4})-(\d{4})-(\d{4})-(\d{4})' \
  alphabet=credit-card-chars

# Create a transformation
vault write transform/transformations/fpe/credit-card \
  template=credit-card-tmpl tweak_source=internal allowed_roles='["payments"]'

# Create a role
vault write transform/role/payments transformations=credit-card

# Encode (encrypt preserving format)
vault write transform/encode/payments value="1234-5678-9012-3456" transformation=credit-card
# Output: "5765-8723-1290-4389" (same format, encrypted)

# Decode
vault write transform/decode/payments value="5765-8723-1290-4389" transformation=credit-card
```

### Masking

```bash
vault write transform/transformations/masking/ssn-mask \
  template=builtin/socialsecuritynumber \
  masking_character="#" allowed_roles='["hr"]'

vault write transform/role/hr transformations=ssn-mask

vault write transform/encode/hr value="123-45-6789" transformation=ssn-mask
# Output: "###-##-6789"
```

### Tokenization

Stores original value in Vault's internal storage, returns opaque token:

```bash
vault write transform/transformations/tokenization/pii-token \
  allowed_roles='["app"]' max_ttl=8760h

vault write transform/encode/app value="John Doe" transformation=pii-token
# Output: random token like "Q4NDcxOTAyMjU1Mzg3..."

vault write transform/decode/app value="Q4NDcxOTAyMjU1Mzg3..." transformation=pii-token
# Output: "John Doe"
```

---

## KMIP Secrets Engine

Key Management Interoperability Protocol for managing encryption keys used by KMIP-compliant clients (databases, storage systems, etc.).

```bash
vault secrets enable kmip

# Configure listener
vault write kmip/config listen_addrs="0.0.0.0:5696" \
  default_tls_client_key_type="ec" default_tls_client_key_bits=256

# Create a scope (organizational unit)
vault write -f kmip/scope/my-scope

# Create a role within the scope
vault write kmip/scope/my-scope/role/my-role \
  tls_client_key_type=ec tls_client_key_bits=256 \
  operation_activate=true operation_get=true operation_create=true \
  operation_destroy=true

# Generate client certificate for KMIP client
vault write -f kmip/scope/my-scope/role/my-role/credential/generate
# Output: certificate, private_key, ca_chain
```

Use cases: MongoDB encrypted storage engine, VMware vSAN encryption, MySQL TDE.

---

## Multi-Tenancy with Namespaces

### Namespace Hierarchy

```bash
# Create hierarchical namespaces
vault namespace create org-a
vault namespace create -namespace=org-a team-frontend
vault namespace create -namespace=org-a team-backend
vault namespace create -namespace=org-a/team-backend microservice-1

# Full path: org-a/team-backend/microservice-1/

# List namespaces
vault namespace list
vault namespace list -namespace=org-a
```

### Cross-Namespace Policies

```hcl
# Policy in root namespace granting access to child namespace
path "org-a/secret/data/*" {
  capabilities = ["read"]
}

# Namespace admin policy (applied within namespace)
path "sys/namespaces/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

### Namespace Quotas

```bash
# Rate limit per namespace (Enterprise)
vault write sys/quotas/rate-limit/org-a-limit \
  path="org-a/" rate=1000 interval=1s burst=2000

# Lease count quota
vault write sys/quotas/lease-count/org-a-lease-limit \
  path="org-a/" max_leases=10000
```

---

## Advanced Lease Management

```bash
# List all leases by prefix
vault list sys/leases/lookup/database/creds/

# Look up specific lease details
vault write sys/leases/lookup lease_id="database/creds/app-role/abc123"

# Revoke all leases for a mount (emergency)
vault lease revoke -prefix -force database/

# Tidy leases (cleanup expired)
vault write -f sys/leases/tidy

# Set max lease TTL for a mount
vault secrets tune -max-lease-ttl=72h database/

# Global max lease TTL
vault write sys/config/max-lease-ttl max_lease_ttl=768h
```

---

## Response Wrapping Patterns

Securely deliver secrets with single-use wrapping tokens:

```bash
# Wrap a secret — returns a wrapping token
vault kv get -wrap-ttl=300 secret/myapp/config
# Output: wrapping_token, creation_time, creation_path

# Programmatic wrapping
curl -H "X-Vault-Token: $TOKEN" -H "X-Vault-Wrap-TTL: 300" \
  $VAULT_ADDR/v1/secret/data/myapp/config

# Unwrap (single use — token is invalidated after)
vault unwrap <wrapping_token>

# Look up wrapping token metadata (without unwrapping)
vault token lookup -accessor <wrapping_accessor>

# Rewrap (rotate the wrapping token)
vault write sys/wrapping/rewrap token=<wrapping_token>
```

---

## Control Groups

Enterprise feature requiring multiple approvals for sensitive operations:

```hcl
# Policy requiring control group authorization
path "secret/data/production/*" {
  capabilities = ["read"]
  control_group {
    factor "authorizer" {
      controlled_capabilities = ["read"]
      identity {
        group_names = ["managers"]
        approvals   = 1
      }
    }
    ttl = "4h"
    max_ttl = "24h"
  }
}
```

```bash
# Workflow:
# 1. User requests secret — gets wrapping token, request is pending
# 2. Authorizer approves
vault write sys/control-group/authorize accessor=<accessor>
# 3. User unwraps the wrapping token to get the secret
vault unwrap <wrapping_token>
```

---

## Performance Standby Nodes

```hcl
# Enable performance standbys (Enterprise)
# vault.hcl on standby nodes
performance_standby_enabled = true
```

```bash
# Check node status
vault status -format=json | jq '.performance_standby'

# Client-side: read from standby, write forwarded to active
# Use X-Vault-Inconsistent=forward-active-node header to force consistency
curl -H "X-Vault-Token: $TOKEN" \
  -H "X-Vault-Inconsistent: forward-active-node" \
  $VAULT_ADDR/v1/secret/data/myapp
```
