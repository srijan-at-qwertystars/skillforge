# KV Policy — access control for KV store paths
#
# Provides scoped read/write access to KV prefixes.
# Template: replace "TEAM_NAME" with the team or application name.
#
# Usage:
#   sed 's/TEAM_NAME/frontend/g' kv-policy.hcl | \
#     consul acl policy create -name "kv-frontend" -rules -

# Full read/write to team-owned KV prefix
key_prefix "config/TEAM_NAME/" {
  policy = "write"
}

# Read-only access to shared global config
key_prefix "config/global/" {
  policy = "read"
}

# Read-only access to feature flags
key_prefix "config/features/" {
  policy = "read"
}

# Deny access to secrets (explicit deny overrides prefix read)
key_prefix "secrets/" {
  policy = "deny"
}

# Allow listing top-level keys (for UI browsing)
key_prefix "config/" {
  policy = "list"
}

# Session management (required for distributed locks)
session_prefix "" {
  policy = "write"
}
