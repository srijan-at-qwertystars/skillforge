---
name: vault-secrets
description: >
  HashiCorp Vault secrets management skill. Use when working with Vault server,
  secrets engines (KV, PKI, Transit, Database), dynamic secrets, secret rotation,
  Vault Agent, AppRole authentication, OIDC/LDAP/Kubernetes auth, transit
  encryption, certificate management, Vault policies/ACLs, lease management,
  Vault namespaces, or Kubernetes Vault integration (injector, CSI, VSO).
  Do NOT use for simple environment variables, AWS Secrets Manager without Vault,
  plain Kubernetes Secrets not managed by Vault, password managers like
  1Password or Bitwarden for team credentials, or general application
  configuration management unrelated to secrets.
---

# HashiCorp Vault Secrets Management

## Installation and Initialization

```bash
# Install (Linux amd64)
wget -qO- https://releases.hashicorp.com/vault/1.15.6/vault_1.15.6_linux_amd64.zip | funzip > /usr/local/bin/vault && chmod +x /usr/local/bin/vault

# Dev server (testing only — in-memory)
vault server -dev -dev-root-token-id="root"

# Production: initialize and unseal
vault operator init -key-shares=5 -key-threshold=3
# Returns 5 unseal keys + initial root token. Store keys separately and securely.
vault operator unseal <key1> && vault operator unseal <key2> && vault operator unseal <key3>
vault status  # Sealed: false

# Set CLI environment
export VAULT_ADDR='https://vault.example.com:8200'
export VAULT_TOKEN='s.xxxxxxxxx'
```

## Secrets Engines

### KV v2 (Key-Value)

```bash
vault secrets enable -version=2 -path=secret kv

vault kv put -mount=secret myapp/db username=admin password=s3cret
vault kv get -mount=secret myapp/db
vault kv get -mount=secret -field=password myapp/db
vault kv list -mount=secret myapp/

# Versioning
vault kv get -mount=secret -version=2 myapp/db
vault kv delete -mount=secret myapp/db          # soft delete latest
vault kv undelete -mount=secret -versions=3 myapp/db
vault kv destroy -mount=secret -versions=1,2 myapp/db  # permanent
vault kv metadata get -mount=secret myapp/db
vault kv metadata put -mount=secret -max-versions=10 myapp/db
```

### PKI (Certificate Authority)

```bash
vault secrets enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki
vault write pki/root/generate/internal common_name="Example Root CA" ttl=87600h
vault write pki/config/urls \
  issuing_certificates="https://vault.example.com:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.example.com:8200/v1/pki/crl"

# Intermediate CA
vault secrets enable -path=pki_int pki
vault write pki_int/intermediate/generate/internal \
  common_name="Example Intermediate CA" | jq -r .data.csr > int.csr
vault write pki/root/sign-intermediate csr=@int.csr ttl=43800h \
  | jq -r .data.certificate > signed.pem
vault write pki_int/intermediate/set-signed certificate=@signed.pem

# Create role and issue certificate
vault write pki_int/roles/web-servers \
  allowed_domains="example.com" allow_subdomains=true max_ttl=720h
vault write pki_int/issue/web-servers common_name="app.example.com" ttl=24h
# Output: certificate, private_key, ca_chain, serial_number
```

### Transit (Encryption as a Service)

```bash
vault secrets enable transit
vault write -f transit/keys/my-app-key

# Encrypt (plaintext must be base64-encoded)
vault write transit/encrypt/my-app-key plaintext=$(echo -n "secret data" | base64)
# Output: ciphertext: vault:v1:AbCdEf...

# Decrypt
vault write transit/decrypt/my-app-key ciphertext="vault:v1:AbCdEf..."
# Output: plaintext (base64) → decode: echo <plaintext> | base64 -d

# Key rotation and rewrapping
vault write -f transit/keys/my-app-key/rotate
vault write transit/rewrap/my-app-key ciphertext="vault:v1:AbCdEf..."
# Re-encrypts with latest key version without exposing plaintext

# HMAC, signing, key config
vault write transit/hmac/my-app-key input=$(echo -n "data" | base64)
vault write transit/sign/my-app-key input=$(echo -n "data" | base64)
vault write transit/keys/my-app-key/config min_decryption_version=2
```

### Database (Dynamic Credentials)

```bash
vault secrets enable database
vault write database/config/mydb \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@db.example.com:5432/mydb" \
  allowed_roles="readonly,readwrite" \
  username="vault_admin" password="admin_pass"

vault write database/roles/readonly db_name=mydb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
    VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h max_ttl=24h

vault read database/creds/readonly
# Output: username: v-approle-readonly-abc123, password: xyz789, lease_id, lease_duration
```

### AWS (Dynamic IAM Credentials)

```bash
vault secrets enable aws
vault write aws/config/root access_key=AKIA... secret_key=... region=us-east-1
vault write aws/roles/s3-reader credential_type=iam_user \
  policy_document=-<<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"*"}]}
EOF
vault read aws/creds/s3-reader
# Output: access_key, secret_key, lease_id — auto-revoked on expiry
```

### SSH (Signed Certificates)

```bash
vault secrets enable -path=ssh-client ssh
vault write ssh-client/config/ca generate_signing_key=true
vault read -field=public_key ssh-client/config/ca > /etc/ssh/trusted-user-ca-keys.pem
# Add to sshd_config: TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
vault write ssh-client/roles/default -<<EOF
{"allow_user_certificates":true,"allowed_users":"*","default_extensions":{"permit-pty":""},"key_type":"ca","default_user":"ubuntu","ttl":"30m"}
EOF
vault write ssh-client/sign/default public_key=@~/.ssh/id_ed25519.pub
```

## Authentication Methods

### Token

```bash
vault token create -policy=my-policy -ttl=1h -use-limit=10
vault token lookup
vault token renew <token>
vault token revoke <token>
```

### AppRole (Machine-to-Machine)

```bash
vault auth enable approle
vault write auth/approle/role/my-app \
  token_policies="my-policy" token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=10m secret_id_num_uses=1

vault read -field=role_id auth/approle/role/my-app/role-id
vault write -f -field=secret_id auth/approle/role/my-app/secret-id
vault write auth/approle/login role_id="<role-id>" secret_id="<secret-id>"
# Output: client_token, accessor, policies, lease_duration
```

### Kubernetes

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

vault write auth/kubernetes/role/webapp \
  bound_service_account_names=webapp-sa \
  bound_service_account_namespaces=production \
  policies=webapp-policy ttl=1h
```

### OIDC

```bash
vault auth enable oidc
vault write auth/oidc/config \
  oidc_discovery_url="https://accounts.google.com" \
  oidc_client_id="..." oidc_client_secret="..." default_role="default"
vault write auth/oidc/role/default \
  allowed_redirect_uris="https://vault.example.com:8200/ui/vault/auth/oidc/oidc/callback" \
  user_claim="email" policies="default" ttl=1h
```

### LDAP

```bash
vault auth enable ldap
vault write auth/ldap/config \
  url="ldaps://ldap.example.com" \
  userdn="ou=Users,dc=example,dc=com" \
  groupdn="ou=Groups,dc=example,dc=com" \
  userattr="uid" groupattr="cn"
vault write auth/ldap/groups/engineers policies=engineering
vault login -method=ldap username=jdoe
```

### AWS IAM

```bash
vault auth enable aws
vault write auth/aws/config/client secret_key=... access_key=...
vault write auth/aws/role/ec2-role auth_type=iam \
  bound_iam_principal_arn="arn:aws:iam::123456:role/my-role" policies=ec2-policy ttl=1h
```

## Policies and ACLs

Write policies in HCL. Attach to tokens, auth methods, or entities.

```hcl
path "secret/data/webapp/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/webapp/*" {
  capabilities = ["list", "read"]
}
path "database/creds/webapp-db" {
  capabilities = ["read"]
}
path "transit/encrypt/webapp-key" {
  capabilities = ["update"]
}
path "transit/decrypt/webapp-key" {
  capabilities = ["update"]
}
# Deny overrides all allows
path "secret/data/admin/*" {
  capabilities = ["deny"]
}
# Templated policy — user-scoped paths
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

Capabilities: `create`, `read`, `update`, `delete`, `list`, `sudo`, `deny`.
Path patterns: `*` matches any chars in segment, `+` matches exactly one segment.
KV v2 paths require `secret/data/` for data, `secret/metadata/` for metadata.

```bash
vault policy write webapp-policy webapp-policy.hcl
vault policy read webapp-policy
vault policy list
vault token create -policy=webapp-policy
```

## Dynamic Secrets and Lease Management

Dynamic secrets are generated on demand with automatic expiration.

```bash
vault read database/creds/readonly
# Output includes lease_id and lease_duration

vault lease renew database/creds/readonly/abcd-1234-efgh
vault lease renew -increment=2h database/creds/readonly/abcd-1234-efgh
vault lease revoke database/creds/readonly/abcd-1234-efgh
vault lease revoke -prefix database/creds/readonly
vault list sys/leases/lookup/database/creds/readonly  # requires sudo

vault secrets tune -default-lease-ttl=1h -max-lease-ttl=24h database/
```

## Vault Agent

Runs as sidecar or daemon for auto-auth, templating, and caching.

```hcl
auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/etc/vault/role-id"
      secret_id_file_path = "/etc/vault/secret-id"
    }
  }
  sink "file" {
    config = { path = "/tmp/vault-token" }
  }
}
cache {
  use_auto_auth_token = true
}
template {
  source      = "/etc/vault/templates/db.tpl"
  destination = "/app/config/db.env"
  perms       = "0600"
  command     = "systemctl restart myapp"
}
vault {
  address = "https://vault.example.com:8200"
}
```

Template file (`db.tpl`):

```
{{ with secret "database/creds/readonly" -}}
DB_USERNAME={{ .Data.username }}
DB_PASSWORD={{ .Data.password }}
{{ end -}}
```

Run: `vault agent -config=vault-agent.hcl`

## Kubernetes Integration

### Vault Agent Injector

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --set "injector.enabled=true" --set "server.enabled=false" \
  --set "injector.externalVaultAddr=https://vault.example.com:8200"
```

Annotate pods to inject secrets:

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "webapp"
    vault.hashicorp.com/agent-inject-secret-db: "database/creds/readonly"
    vault.hashicorp.com/agent-inject-template-db: |
      {{- with secret "database/creds/readonly" -}}
      postgresql://{{ .Data.username }}:{{ .Data.password }}@db:5432/app
      {{- end }}
```

Secret appears at `/vault/secrets/db` inside the container.

### CSI Driver

```bash
helm install vault hashicorp/vault --set "csi.enabled=true" --set "injector.enabled=false"
```

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.example.com:8200"
    roleName: "webapp"
    objects: |
      - objectName: "db-password"
        secretPath: "secret/data/webapp/db"
        secretKey: "password"
```

Mount as volume in pod spec. Secrets refresh on pod restart.

### Vault Secrets Operator (VSO)

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system --create-namespace
```

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: webapp
    serviceAccount: default
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: webapp-secret
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: webapp/config
  type: kv-v2
  refreshAfter: 60s
  destination:
    name: webapp-secret
    create: true
```

## Namespaces and Multi-Tenancy

Enterprise feature for isolating teams, environments, or tenants:

```bash
vault namespace create engineering
vault namespace create -namespace=engineering frontend
vault namespace list
export VAULT_NAMESPACE=engineering  # or use -namespace flag per command
vault secrets enable -path=secret kv-v2
vault kv put -mount=secret app/key value=123
```

## High Availability

### Raft Integrated Storage

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

### Auto-Unseal

Eliminate manual unseal. Supports AWS KMS, Azure Key Vault, GCP Cloud KMS, Transit.

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key"
}
```

```bash
vault operator raft list-peers
vault operator raft join https://vault-1:8200
vault operator raft autopilot state
```

## Monitoring and Audit Logging

```bash
vault audit enable file file_path=/var/log/vault/audit.log
vault audit enable syslog tag="vault" facility="AUTH"
vault audit list
vault audit disable file/
```

Audit logs capture every request/response with HMAC-protected sensitive fields. Enable at least two audit devices — Vault blocks operations if all devices fail.

Prometheus: add `telemetry { prometheus_retention_time = "30s" }` to config, scrape `GET /v1/sys/metrics?format=prometheus`.

## CLI Quick Reference

```bash
vault status                          # Server seal status
vault operator init / unseal / seal   # Lifecycle
vault operator raft list-peers        # Cluster state
vault login [-method=oidc|ldap]       # Authenticate
vault token lookup / renew / revoke   # Token management
vault secrets enable/list/disable     # Engine lifecycle
vault secrets tune -default-lease-ttl=1h <path>
vault kv put/get/delete/list -mount=<m> <path>
vault lease renew/revoke [-prefix] <lease-id>
vault policy write/read/list/delete <name> [file]
vault namespace create/list/delete    # Enterprise
vault debug -duration=5m              # Diagnostics bundle
```

## Additional Resources

**References:** [Advanced Patterns](references/advanced-patterns.md) (secret zero, Agent caching, response wrapping, control groups, Sentinel, replication, batch/service tokens, identity, OIDC provider, Terraform) · [Troubleshooting](references/troubleshooting.md) (seal failures, token expiry, lease storms, storage perf, audit flooding, cert rotation, K8s auth, AppRole wrapping, Raft recovery, DR) · [Kubernetes Integration](references/kubernetes-integration.md)

**Scripts:** [setup-vault.sh](scripts/setup-vault.sh) (Docker dev/prod setup with init, unseal, engines, policies) · [rotate-secrets.sh](scripts/rotate-secrets.sh) (zero-downtime DB credential rotation) · [setup-vault-dev.sh](scripts/setup-vault-dev.sh) · [vault-backup.sh](scripts/vault-backup.sh)

**Assets:** [vault-policy.hcl](assets/vault-policy.hcl) (admin, readonly, app, CI/CD, operator, user-workspace, db-admin policies) · [vault-agent-config.hcl](assets/vault-agent-config.hcl) (production Agent with auto-auth, caching, templates) · [docker-compose.yml](assets/docker-compose.yml) (3-node HA Raft cluster + Prometheus + Grafana) · [docker-compose-vault.yml](assets/docker-compose-vault.yml) · [vault-policy-templates/](assets/vault-policy-templates/)
<!-- tested: pass -->
