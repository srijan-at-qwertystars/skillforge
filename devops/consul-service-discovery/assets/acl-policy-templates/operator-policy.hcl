# Operator Policy — privileged access for cluster operations
#
# Assign to operations/platform team members who manage the Consul cluster.
# Includes Raft, ACL management, snapshot, and config entry permissions.
#
# Usage:
#   consul acl policy create -name "operator-policy" -rules @operator-policy.hcl
#   consul acl token create -description "Operator token" -policy-name "operator-policy"

# Full node management
node_prefix "" {
  policy = "write"
}

# Full service management
service_prefix "" {
  policy = "write"
}

# Full KV management
key_prefix "" {
  policy = "write"
}

# Agent management on any agent
agent_prefix "" {
  policy = "write"
}

# Session management
session_prefix "" {
  policy = "write"
}

# Operator permissions (Raft, autopilot, area, keyring)
operator = "write"

# ACL management (create/update/delete policies, tokens, roles)
acl = "write"

# Prepared query management
query_prefix "" {
  policy = "write"
}

# Mesh / Connect config entries
mesh = "write"
peering = "write"

# Event firing
event_prefix "" {
  policy = "write"
}
