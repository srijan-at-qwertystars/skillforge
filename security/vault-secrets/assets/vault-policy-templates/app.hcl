# Vault Application Policy — Scoped access for application workloads
# Assign to: Application service accounts, AppRole roles
# Customize: Replace "myapp" with your application name

# KV v2 — Read application secrets
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
path "secret/metadata/myapp/*" {
  capabilities = ["read", "list"]
}

# KV v2 — Read shared configuration
path "secret/data/shared/*" {
  capabilities = ["read"]
}

# Database — Request dynamic credentials
path "database/creds/myapp-*" {
  capabilities = ["read"]
}

# Transit — Encrypt/decrypt with application key
path "transit/encrypt/myapp-key" {
  capabilities = ["update"]
}
path "transit/decrypt/myapp-key" {
  capabilities = ["update"]
}

# PKI — Issue certificates
path "pki/issue/myapp-certs" {
  capabilities = ["create", "update"]
}

# Token — Self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}

# Health check (unauthenticated, but policy still useful for documentation)
path "sys/health" {
  capabilities = ["read", "sudo"]
}
