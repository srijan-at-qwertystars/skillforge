# Service Policy — allows a service to register, discover, and read config
#
# Template: replace "SERVICE_NAME" with your actual service name.
#
# Usage:
#   sed 's/SERVICE_NAME/web/g' service-policy.hcl | \
#     consul acl policy create -name "web-policy" -rules -
#   consul acl token create -description "web token" -policy-name "web-policy"

# Allow registering and reading this specific service
service "SERVICE_NAME" {
  policy = "write"
}

# Allow discovering other services (for upstream connections)
service_prefix "" {
  policy = "read"
}

# Allow reading nodes (required for service discovery)
node_prefix "" {
  policy = "read"
}

# Allow reading service-specific configuration
key_prefix "config/SERVICE_NAME/" {
  policy = "read"
}

# Allow reading global configuration
key_prefix "config/global/" {
  policy = "read"
}

# Allow Connect intentions for this service (if using service mesh)
service "SERVICE_NAME" {
  intentions = "read"
}
