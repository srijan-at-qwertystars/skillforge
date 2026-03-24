# Vault Read-Only Policy — View secrets without modification
# Assign to: Auditors, monitoring systems, read-only service accounts
# Customize: Restrict paths further for least-privilege access

# KV v2 — Read all secrets (no write)
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}

# System — Read cluster status
path "sys/health" {
  capabilities = ["read"]
}
path "sys/seal-status" {
  capabilities = ["read"]
}
path "sys/host-info" {
  capabilities = ["read"]
}
path "sys/leader" {
  capabilities = ["read"]
}

# List mounts and auth methods (metadata only)
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
path "sys/policies/acl/*" {
  capabilities = ["read"]
}

# Token — Self-management only
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
