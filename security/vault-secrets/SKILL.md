---
name: vault-secrets
description: >
  Guide for working with HashiCorp Vault secrets management including secrets engines
  (KV v2, Transit, PKI, Database, AWS, GCP), auth methods (Token, AppRole, Kubernetes,
  OIDC, LDAP), policies in HCL, Vault Agent auto-auth/templating/caching, dynamic
  secrets with lease management, namespaces, HA deployment, audit logging, and the
  Vault Secrets Operator for Kubernetes. Triggers on: "HashiCorp Vault", "vault secrets",
  "vault auth method", "vault policy", "dynamic secrets", "vault agent", "vault transit
  engine", "PKI secrets engine", "vault unseal", "vault namespace", "vault HA",
  "vault audit", "VaultStaticSecret", "VaultDynamicSecret", "vault approle",
  "vault OIDC". NOT for AWS Secrets Manager, Azure Key Vault, GCP Secret Manager,
  SOPS, sealed-secrets, or general encryption without Vault.
---

# HashiCorp Vault Secrets Management

## Architecture

Vault uses a client-server model. The server stores encrypted data in a **storage backend** (Consul, Raft integrated storage, S3, etc.). On startup, Vault is **sealed** — it knows where data is but cannot decrypt it.

### Seal/Unseal

- Vault uses **Shamir's Secret Sharing** by default: the master key is split into N shares, M of which are needed to unseal (e.g., 5 shares, 3 threshold).
- **Auto-unseal** delegates unsealing to a trusted KMS (AWS KMS, Azure Key Vault, GCP Cloud KMS, Transit engine of another Vault).
- Once unsealed, Vault loads the encryption key into memory and serves requests.

### Storage Backends

| Backend | HA Support | Notes |
|---------|-----------|-------|
| Integrated Raft | Yes | Recommended for production. Built-in, no external dependency. |
| Consul | Yes | Legacy recommended. Requires separate Consul cluster. |
| S3 | No | Simple but no HA. Good for dev/test. |
| DynamoDB | Yes | AWS-native HA option. |

**Internal flow:** Client → Listener (TCP/TLS :8200) → Core → Barrier (encryption layer) → Storage Backend. Core manages Auth Methods, Secrets Engines, and Audit Devices.

## Secrets Engines

Enable at a path; each engine is isolated. API: `POST /v1/sys/mounts/{path}`.

### KV Version 2 (Key-Value)

```bash
vault secrets enable -version=2 -path=secret kv
vault kv put secret/myapp/config db_host="db.example.com" db_port="5432"
vault kv get -format=json secret/myapp/config
# Output: { "data": { "data": { "db_host": "db.example.com", "db_port": "5432" },
#            "metadata": { "version": 1, "created_time": "2025-01-15T10:30:00Z" } } }
vault kv get -version=1 secret/myapp/config     # Read specific version
vault kv delete secret/myapp/config              # Soft-delete (recoverable)
vault kv destroy -versions=1 secret/myapp/config # Permanent destroy
vault kv metadata put -max-versions=10 secret/myapp/config
```

### Transit Engine (Encryption as a Service)

```bash
vault secrets enable transit
vault write -f transit/keys/my-app-key
# Encrypt (plaintext must be base64-encoded)
vault write transit/encrypt/my-app-key plaintext=$(echo -n "secret-data" | base64)
# Output: { "data": { "ciphertext": "vault:v1:AbC123xYz..." } }
# Decrypt
vault write transit/decrypt/my-app-key ciphertext="vault:v1:AbC123xYz..."
# Output: { "data": { "plaintext": "c2VjcmV0LWRhdGE=" } } → base64 -d → "secret-data"
# Key rotation (new version encrypts, old versions still decrypt)
vault write -f transit/keys/my-app-key/rotate
```

### PKI Secrets Engine

```bash
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki
vault write pki/root/generate/internal common_name="example.com" ttl=87600h
vault write pki/roles/web-certs \
  allowed_domains="example.com" allow_subdomains=true max_ttl=720h
vault write pki/issue/web-certs common_name="app.example.com" ttl=24h
# Output includes: certificate, issuing_ca, private_key, serial_number
```

### Database Secrets Engine (Dynamic Credentials)

```bash
vault secrets enable database
vault write database/config/mydb \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@db.example.com:5432/mydb" \
  allowed_roles="app-role" username="vault_admin" password="admin_pass"
vault write database/roles/app-role db_name=mydb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h max_ttl=24h
vault read database/creds/app-role
# Output: { "data": { "username": "v-approle-app-rol-abc123", "password": "A1b2C3-randomized" },
#           "lease_id": "database/creds/app-role/abcd1234", "lease_duration": 3600 }
```

### Cloud Secrets Engines (AWS Example)

```bash
vault secrets enable aws
vault write aws/config/root access_key=AKIA... secret_key=... region=us-east-1
vault write aws/roles/deploy-role credential_type=iam_user \
  policy_document=-<<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:*","Resource":"*"}]}
EOF
vault read aws/creds/deploy-role
# Output: access_key, secret_key, security_token (auto-revoked on lease expiry)
```

## Auth Methods

All auth methods ultimately produce a **Vault token**. Enable under `auth/` prefix.

### Token Auth (Built-in)

```bash
vault token create -policy=app-policy -ttl=1h -renewable=true
vault token lookup <token>
vault token revoke <token>
```

### AppRole (Machine-to-Machine)

```bash
vault auth enable approle
vault write auth/approle/role/my-app \
  token_policies="app-policy" token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=720h secret_id_num_uses=0
vault read auth/approle/role/my-app/role-id        # Stable identifier
vault write -f auth/approle/role/my-app/secret-id   # Rotatable credential
vault write auth/approle/login role_id="<role-id>" secret_id="<secret-id>"
```

### Kubernetes Auth

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
vault write auth/kubernetes/role/app \
  bound_service_account_names=app-sa bound_service_account_namespaces=default \
  policies=app-policy ttl=1h
# Pod login via API:
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s --request POST --data "{\"jwt\":\"$JWT\",\"role\":\"app\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login
```

### OIDC Auth

```bash
vault auth enable oidc
vault write auth/oidc/config \
  oidc_discovery_url="https://accounts.google.com" \
  oidc_client_id="..." oidc_client_secret="..." default_role="reader"
vault write auth/oidc/role/reader bound_audiences="..." \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="email" policies="reader-policy"
```

### LDAP Auth

```bash
vault auth enable ldap
vault write auth/ldap/config url="ldaps://ldap.example.com" \
  userdn="ou=Users,dc=example,dc=com" groupdn="ou=Groups,dc=example,dc=com" \
  groupattr="cn" userattr="uid"
vault write auth/ldap/groups/engineers policies=eng-policy
```

## Policies (HCL)

Policies define access. Default deny — must explicitly grant. Attached to tokens.

```hcl
path "secret/data/myapp/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/data/shared/config" {
  capabilities = ["read"]
}
path "secret/data/myapp/admin" {
  capabilities = ["deny"]   # deny overrides allow
}
path "database/creds/+" {    # + matches one path segment
  capabilities = ["read"]
}
path "secret/metadata/*" {   # * matches any remaining path
  capabilities = ["list"]
}
path "secret/data/{{identity.entity.name}}/*" {  # Templated policy
  capabilities = ["create", "read", "update", "delete"]
}
```

```bash
vault policy write app-policy app-policy.hcl
vault token create -policy=app-policy
```

**Capabilities:** `create`, `read`, `update`, `delete`, `list`, `sudo`, `deny`. Path `+` matches one segment; `*` matches remainder. Example: `secret/data/+/config` matches `secret/data/app1/config` but NOT `secret/data/app1/sub/config`.

## Vault Agent

Runs as a sidecar or daemon. Handles auto-auth, secret templating, and response caching.

### Configuration Example (`vault-agent.hcl`)

```hcl
vault { address = "https://vault.example.com:8200" }
auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = { role = "app" }
  }
  sink "file" {
    config = { path = "/home/vault/.vault-token", mode = 0640 }
  }
}
cache {
  use_auto_auth_token = true
  persist = { type = "kubernetes", path = "/vault/agent-cache" }
}
listener "tcp" { address = "127.0.0.1:8100", tls_disable = true }
template {
  source      = "/vault/templates/app.ctmpl"
  destination = "/app/config/secrets.env"
  perms       = 0644
  command     = "pkill -HUP myapp"
  error_on_missing_key = true
}
template {
  contents    = "{{ with secret \"database/creds/app\" }}DB_USER={{ .Data.username }}\nDB_PASS={{ .Data.password }}{{ end }}"
  destination = "/app/config/db.env"
}
```

### Template Syntax (Consul Template)

```
{{ with secret "secret/data/myapp/config" }}export API_KEY="{{ .Data.data.api_key }}"{{ end }}

{{ with secret "pki/issue/web-certs" "common_name=app.example.com" }}
{{ .Data.certificate }}{{ .Data.private_key }}{{ end }}

{{ range secrets "secret/metadata/myapp/" }}{{ with secret (printf "secret/data/myapp/%s" .) }}{{ .Data.data | toJSON }}{{ end }}{{ end }}
```

Run: `vault agent -config=vault-agent.hcl`

## Lease Management

Dynamic secrets (DB creds, cloud creds) come with **leases**.

```bash
vault list sys/leases/lookup/database/creds/app-role
vault lease renew database/creds/app-role/abcd1234
vault lease renew -increment=3600 database/creds/app-role/abcd1234
vault lease revoke database/creds/app-role/abcd1234
vault lease revoke -prefix database/creds/app-role    # Revoke all under prefix
# API: curl -H "X-Vault-Token: $VAULT_TOKEN" --request PUT \
#   --data '{"lease_id":"database/creds/app-role/abcd1234","increment":3600}' \
#   $VAULT_ADDR/v1/sys/leases/renew
```

## Namespaces (Enterprise)

Namespaces provide tenant isolation within a single Vault cluster.

```bash
vault namespace create team-a
export VAULT_NAMESPACE=team-a
vault secrets enable -path=secret kv-v2
# Or via API header: -H "X-Vault-Namespace: team-a"
```

Namespaces are hierarchical (`parent/child`). Policies, auth methods, and secrets engines are scoped per namespace.

## HA Deployment

### Integrated Raft Storage (Recommended)

```hcl
storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
  retry_join { leader_api_addr = "https://vault-2:8200" }
  retry_join { leader_api_addr = "https://vault-3:8200" }
}
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/cert.pem"
  tls_key_file  = "/opt/vault/tls/key.pem"
}
api_addr     = "https://vault-1:8200"
cluster_addr = "https://vault-1:8201"
```

Minimum 3 or 5 nodes for quorum. One leader, rest are standby (forward requests). `autopilot` manages health checks, dead server cleanup, and server stabilization.

## Audit Logging

```bash
vault audit enable file file_path=/var/log/vault/audit.log
vault audit enable syslog tag="vault" facility="AUTH"
vault audit enable socket address="127.0.0.1:9090" socket_type="tcp"
```

Every request/response is logged (sensitive values HMAC'd). At least one audit device must succeed or Vault stops serving requests.

## Vault Secrets Operator for Kubernetes (VSO)

The VSO (v1.x) syncs Vault secrets into Kubernetes Secrets via CRDs.

### Installation

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system --create-namespace
```

### CRD Configuration

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata: { name: vault-connection, namespace: app-ns }
spec: { address: "https://vault.example.com:8200", skipTLSVerify: false }
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata: { name: vault-auth, namespace: app-ns }
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes: { role: app, serviceAccount: default }
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata: { name: app-secret, namespace: app-ns }
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: myapp/config
  type: kv-v2
  refreshAfter: 60s
  destination: { name: app-k8s-secret, create: true }
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata: { name: db-creds, namespace: app-ns }
spec:
  vaultAuthRef: vault-auth
  mount: database
  path: creds/app-role
  renewalPercent: 67
  destination: { name: db-k8s-secret, create: true }
```

The operator handles lease renewal, secret rotation, and drift remediation automatically.

## Quick Reference: Common API Patterns

```bash
curl $VAULT_ADDR/v1/sys/health              # Health check (unauthenticated)
curl $VAULT_ADDR/v1/sys/seal-status          # Seal status
vault secrets list -format=json              # List secrets engines
vault auth list -format=json                 # List auth methods
vault token capabilities secret/data/myapp/config  # Check own capabilities
vault kv get -wrap-ttl=120 secret/myapp/config     # Response wrapping
vault unwrap <wrapping_token>                       # Unwrap
```

## References

Detailed guides in [`references/`](references/):

| File | Topics |
|------|--------|
| [`advanced-patterns.md`](references/advanced-patterns.md) | Templated policies, Sentinel EGP/RGP, performance & DR replication, seal migration, auto-unseal (AWS KMS, Azure, GCP, Transit), identity secrets engine, transform engine (FPE/masking/tokenization), KMIP, multi-tenancy with namespaces, control groups, response wrapping patterns |
| [`troubleshooting.md`](references/troubleshooting.md) | Permission denied errors, seal status issues, lease not found, token expiry, auth method debugging (AppRole, K8s, OIDC, LDAP), Raft & Consul storage issues, HA failover, split-brain recovery, audit log analysis, performance tuning, disaster recovery procedures |
| [`kubernetes-integration.md`](references/kubernetes-integration.md) | Vault Agent Injector (annotations, templates), CSI Provider, Vault Secrets Operator (VSO) CRDs, Kubernetes auth method setup, init-container vs sidecar patterns, Helm chart config, External Secrets Operator integration, network policies, monitoring |

## Scripts

Operational scripts in [`scripts/`](scripts/):

| Script | Description |
|--------|-------------|
| [`setup-vault-dev.sh`](scripts/setup-vault-dev.sh) | Starts a Vault dev server with KV v2, Transit, PKI engines, AppRole/Userpass auth, sample policies, and test secrets. Use `--port` and `--no-server` flags. |
| [`vault-backup.sh`](scripts/vault-backup.sh) | Takes Raft snapshots with compression, checksum verification, optional S3 upload, and retention-based rotation. Suitable for cron. |
| [`rotate-secrets.sh`](scripts/rotate-secrets.sh) | Rotates database/AWS dynamic credentials, Transit keys, and KV secrets. Supports `--dry-run`, `--force`, and lease prefix revocation. |

## Assets

Reusable configuration templates in [`assets/`](assets/):

| Asset | Description |
|-------|-------------|
| [`vault-helm-values.yaml`](assets/vault-helm-values.yaml) | Production Helm values for HA Vault on Kubernetes with Raft storage, AWS KMS auto-unseal, TLS, audit storage, injector, and CSI provider. |
| [`vault-policy-templates/`](assets/vault-policy-templates/) | HCL policy templates: `admin.hcl` (full sudo), `app.hcl` (scoped app access), `ci-cd.hcl` (pipeline read-only), `readonly.hcl` (auditor). |
| [`docker-compose-vault.yml`](assets/docker-compose-vault.yml) | Docker Compose with Vault, Consul backend, Vault Agent sidecar, and sample Nginx app for local development. |
| [`vault-agent-config.hcl`](assets/vault-agent-config.hcl) | Production Agent config with Kubernetes auto-auth, response caching, API proxy listener, and templates for DB creds, TLS certs, and env files. |
| [`github-actions-vault.yml`](assets/github-actions-vault.yml) | GitHub Actions workflow using JWT/OIDC auth (no stored secrets), AppRole fallback, and multi-environment matrix deployment. |
