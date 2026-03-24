# Vault Admin Policy — Full access to all Vault operations
# Assign to: Vault administrators, break-glass accounts
# WARNING: This grants sudo on all paths. Use sparingly.

# Full access to all paths
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
