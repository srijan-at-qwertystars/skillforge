# Agent Policy — allows node registration and basic service/KV read
#
# Assign to agent tokens so Consul agents can register themselves,
# discover other nodes, and participate in anti-entropy.
#
# Usage:
#   consul acl policy create -name "agent-policy" -rules @agent-policy.hcl
#   consul acl token create -description "Agent token" -policy-name "agent-policy"

# Allow the agent to register its own node
node_prefix "" {
  policy = "write"
}

# Allow reading all services (for DNS and health checks)
service_prefix "" {
  policy = "read"
}

# Allow the agent to register its own checks
agent_prefix "" {
  policy = "write"
}

# Allow reading KV for configuration (optional, restrict prefix as needed)
key_prefix "config/" {
  policy = "read"
}
