# Production Vault Agent Configuration
# Handles auto-authentication, response caching, and secret templating.
#
# Usage:
#   vault agent -config=vault-agent-config.hcl
#
# This configuration:
#   - Authenticates via Kubernetes service account (or AppRole fallback)
#   - Caches responses locally to reduce Vault server load
#   - Renders secrets to files using Consul Template syntax
#   - Exposes a local listener for applications to use as a proxy

# --- Vault Server Connection ---
vault {
  address = "https://vault.example.com:8200"
  retry {
    num_retries = 5
    backoff     = "250ms"
    max_backoff = "1m"
  }
}

# --- Auto-Authentication ---
auto_auth {
  # Primary: Kubernetes auth
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role       = "app"
      token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    }
  }

  # Sink: Write token to file for application use
  sink "file" {
    config = {
      path = "/vault/agent/token"
      mode = 0640
    }
  }

  # Sink: Wrapped token for enhanced security (optional)
  # sink "file" {
  #   wrap_ttl = "5m"
  #   config = {
  #     path = "/vault/agent/wrapped-token"
  #     mode = 0640
  #   }
  # }
}

# --- Response Caching ---
cache {
  use_auto_auth_token = true

  # Persist cache across restarts (Kubernetes-aware)
  persist = {
    type = "kubernetes"
    path = "/vault/agent/cache"
  }
}

# --- API Proxy Listener ---
# Applications connect to this instead of Vault directly.
# Agent handles authentication and caching transparently.
listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}

# --- Secret Templates ---

# Application configuration file
template {
  source      = "/vault/templates/app-config.ctmpl"
  destination = "/vault/secrets/app-config.json"
  perms       = 0644

  # Restart the application when secrets change
  command = "sh -c 'kill -HUP $(pidof myapp) 2>/dev/null || true'"

  # Fail if template references a missing key
  error_on_missing_key = true

  # Wait for Vault to be available before rendering
  wait {
    min = "5s"
    max = "30s"
  }
}

# Database credentials (dynamic)
template {
  contents    = <<-EOT
    {{ with secret "database/creds/app-role" }}
    DB_HOST=db.example.com
    DB_PORT=5432
    DB_USER={{ .Data.username }}
    DB_PASS={{ .Data.password }}
    {{ end }}
  EOT
  destination = "/vault/secrets/db-credentials.env"
  perms       = 0600
  command     = "sh -c 'kill -HUP $(pidof myapp) 2>/dev/null || true'"
}

# TLS certificate (auto-renewed)
template {
  contents    = <<-EOT
    {{ with secret "pki/issue/app-certs" "common_name=app.example.com" "ttl=24h" }}
    {{ .Data.certificate }}
    {{ .Data.issuing_ca }}
    {{ end }}
  EOT
  destination = "/vault/secrets/tls.crt"
  perms       = 0644
  command     = "sh -c 'nginx -s reload 2>/dev/null || true'"
}

template {
  contents    = <<-EOT
    {{ with secret "pki/issue/app-certs" "common_name=app.example.com" "ttl=24h" }}
    {{ .Data.private_key }}
    {{ end }}
  EOT
  destination = "/vault/secrets/tls.key"
  perms       = 0600
}

# Shared configuration (all keys as env vars)
template {
  contents    = <<-EOT
    {{ with secret "secret/data/myapp/config" }}
    {{ range $key, $value := .Data.data }}
    {{ $key }}={{ $value }}
    {{ end }}
    {{ end }}
  EOT
  destination = "/vault/secrets/config.env"
  perms       = 0644
}

# --- Template Configuration (Global) ---
template_config {
  # Exit agent if template rendering fails after retries
  exit_on_retry_failure = true

  # Re-render static secrets periodically (default: 5m)
  static_secret_render_interval = "30s"

  # Maximum stale time for cached secrets
  max_connections_per_host = 10
}
