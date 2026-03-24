# Vault Policy Templates
# Collection of reusable Vault ACL policies for common roles.
# Apply with: vault policy write <name> vault-policy.hcl
# Or extract individual policies and apply separately.

# ============================================================================
# ADMIN POLICY — Full cluster administration
# Usage: vault policy write admin <(sed -n '/^# --- ADMIN/,/^# --- END ADMIN/p' vault-policy.hcl | grep -v '^# ---')
# ============================================================================

# --- ADMIN ---
# Full administrative access to all Vault operations
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
# --- END ADMIN ---


# ============================================================================
# READ-ONLY POLICY — Read access to secrets, no modifications
# Usage: vault policy write readonly <policy-file>
# ============================================================================

# --- READONLY ---
# Read and list all KV v2 secrets
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}

# Health and status endpoints
path "sys/health" {
  capabilities = ["read"]
}
path "sys/seal-status" {
  capabilities = ["read"]
}
path "sys/host-info" {
  capabilities = ["read"]
}

# List available secrets engines and auth methods
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/auth" {
  capabilities = ["read"]
}

# Read policies (not modify)
path "sys/policies/acl/*" {
  capabilities = ["read", "list"]
}

# Token self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
# --- END READONLY ---


# ============================================================================
# APPLICATION POLICY — Scoped access for a specific application
# Customize: Replace "myapp" with your application name
# ============================================================================

# --- APP-SPECIFIC ---
# Application secrets (KV v2)
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/myapp/*" {
  capabilities = ["list", "read"]
}

# Shared configuration (read-only)
path "secret/data/shared/*" {
  capabilities = ["read"]
}

# Dynamic database credentials
path "database/creds/myapp-db" {
  capabilities = ["read"]
}

# Transit encryption (encrypt/decrypt only, no key management)
path "transit/encrypt/myapp-key" {
  capabilities = ["update"]
}
path "transit/decrypt/myapp-key" {
  capabilities = ["update"]
}

# PKI certificate issuance
path "pki/issue/myapp-certs" {
  capabilities = ["create", "update"]
}

# Token self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
# --- END APP-SPECIFIC ---


# ============================================================================
# CI/CD POLICY — Pipeline access for build and deploy
# ============================================================================

# --- CI-CD ---
# Read deployment secrets
path "secret/data/ci/*" {
  capabilities = ["read"]
}
path "secret/metadata/ci/*" {
  capabilities = ["list"]
}

# Read application configs for deployment
path "secret/data/deploy/*" {
  capabilities = ["read"]
}
path "secret/metadata/deploy/*" {
  capabilities = ["list"]
}

# Generate dynamic cloud credentials for infrastructure provisioning
path "aws/creds/ci-deploy" {
  capabilities = ["read"]
}
path "gcp/roleset/ci-deploy/token" {
  capabilities = ["read"]
}

# Issue short-lived TLS certificates for deployment
path "pki/issue/ci-certs" {
  capabilities = ["create", "update"]
}

# Transit signing for artifact verification
path "transit/sign/ci-signing-key" {
  capabilities = ["update"]
}
path "transit/verify/ci-signing-key" {
  capabilities = ["update"]
}

# Token self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
# --- END CI-CD ---


# ============================================================================
# OPERATOR POLICY — Day-to-day operations without full admin
# ============================================================================

# --- OPERATOR ---
# View cluster status
path "sys/health" {
  capabilities = ["read"]
}
path "sys/seal-status" {
  capabilities = ["read"]
}
path "sys/leader" {
  capabilities = ["read"]
}
path "sys/ha-status" {
  capabilities = ["read"]
}
path "sys/host-info" {
  capabilities = ["read", "sudo"]
}

# Manage leases (renew, revoke)
path "sys/leases/lookup/*" {
  capabilities = ["read", "list", "sudo"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/revoke-prefix/*" {
  capabilities = ["update", "sudo"]
}

# Manage tokens
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke" {
  capabilities = ["update"]
}
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Read audit logs configuration
path "sys/audit" {
  capabilities = ["read", "list"]
}

# Read metrics
path "sys/metrics" {
  capabilities = ["read"]
}

# Raft operations
path "sys/storage/raft/autopilot/state" {
  capabilities = ["read"]
}
path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Read policies
path "sys/policies/acl/*" {
  capabilities = ["read", "list"]
}

# Read mounts and auth configuration
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/auth" {
  capabilities = ["read"]
}
# --- END OPERATOR ---


# ============================================================================
# USER-WORKSPACE POLICY — Per-user scoped secrets using identity templates
# ============================================================================

# --- USER-WORKSPACE ---
# Each user gets their own secret namespace
path "secret/data/users/{{identity.entity.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/users/{{identity.entity.name}}/*" {
  capabilities = ["list", "read", "delete"]
}

# Users can manage their own cubbyhole
path "cubbyhole/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Token self-service
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}

# Identity self-lookup
path "identity/entity/id/{{identity.entity.id}}" {
  capabilities = ["read"]
}
# --- END USER-WORKSPACE ---


# ============================================================================
# DATABASE-ADMIN POLICY — Manage database secrets engine
# ============================================================================

# --- DATABASE-ADMIN ---
path "database/config/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "database/roles/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "database/rotate-root/*" {
  capabilities = ["update"]
}
path "database/creds/*" {
  capabilities = ["read"]
}
path "sys/leases/lookup/database/*" {
  capabilities = ["read", "list", "sudo"]
}
path "sys/leases/revoke-prefix/database/*" {
  capabilities = ["update", "sudo"]
}
# --- END DATABASE-ADMIN ---
