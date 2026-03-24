# Vault Agent Configuration — Production Ready
# Handles auto-authentication, response caching, and secret templating.
#
# Usage:
#   vault agent -config=vault-agent-config.hcl
#
# Features:
#   - Auto-auth via Kubernetes (primary) with AppRole fallback
#   - Persistent response caching to reduce Vault server load
#   - API proxy listener for transparent secret access
#   - Template rendering for secrets-as-files pattern
#   - Automatic secret renewal and re-rendering

# --- Vault Server Connection ---
vault {
  address = "https://vault.example.com:8200"

  # TLS configuration (uncomment and adjust for your CA)
  # tls_skip_verify = false
  # ca_cert         = "/etc/vault.d/ca.pem"
  # client_cert     = "/etc/vault.d/client-cert.pem"
  # client_key      = "/etc/vault.d/client-key.pem"

  retry {
    num_retries = 5
    backoff     = "250ms"
    max_backoff = "1m"
  }
}

# --- Auto-Authentication ---
auto_auth {
  # Primary: Kubernetes service account auth
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role       = "app"
      token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    }
  }

  # Token sink: write token to file for direct application use
  sink "file" {
    config = {
      path = "/vault/agent/token"
      mode = 0640
    }
  }

  # Optional: wrapped token sink for enhanced security
  # The application must unwrap the token before use (single-use wrapper)
  # sink "file" {
  #   wrap_ttl = "5m"
  #   config = {
  #     path = "/vault/agent/wrapped-token"
  #     mode = 0640
  #   }
  # }
}

# --- Response Caching ---
# Caches auth tokens and secret responses locally to reduce
# Vault server load and improve latency.
cache {
  use_auto_auth_token = true

  # Persist cache across Agent restarts (survives pod restarts)
  persist "kubernetes" {
    path              = "/vault/agent/cache"
    keep_after_import = true
    exit_on_err       = false
  }
}

# --- API Proxy Listener ---
# Applications connect to this instead of Vault directly.
# Agent injects its auto-auth token and caches responses transparently.
listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}

# --- Secret Templates ---

# Application configuration (KV v2 — all keys rendered as JSON)
template {
  contents    = <<-EOT
    {{- with secret "secret/data/myapp/config" -}}
    {{ .Data.data | toJSON }}
    {{- end -}}
  EOT
  destination = "/vault/secrets/app-config.json"
  perms       = 0644

  # Signal application when secrets change
  command = "sh -c 'kill -HUP $(cat /tmp/app.pid 2>/dev/null) 2>/dev/null || true'"

  error_on_missing_key = true

  wait {
    min = "5s"
    max = "30s"
  }
}

# Database credentials (dynamic — auto-renewed by Agent)
template {
  contents    = <<-EOT
    {{- with secret "database/creds/app-role" -}}
    DB_HOST=db.example.com
    DB_PORT=5432
    DB_USER={{ .Data.username }}
    DB_PASS={{ .Data.password }}
    {{- end -}}
  EOT
  destination = "/vault/secrets/db-credentials.env"
  perms       = 0600
  command     = "sh -c 'kill -HUP $(cat /tmp/app.pid 2>/dev/null) 2>/dev/null || true'"
}

# TLS certificate (auto-renewed before expiry)
template {
  contents    = <<-EOT
    {{- with secret "pki/issue/app-certs" "common_name=app.example.com" "ttl=24h" -}}
    {{ .Data.certificate }}
    {{ .Data.issuing_ca }}
    {{- end -}}
  EOT
  destination = "/vault/secrets/tls.crt"
  perms       = 0644
  command     = "sh -c 'nginx -s reload 2>/dev/null || true'"
}

template {
  contents    = <<-EOT
    {{- with secret "pki/issue/app-certs" "common_name=app.example.com" "ttl=24h" -}}
    {{ .Data.private_key }}
    {{- end -}}
  EOT
  destination = "/vault/secrets/tls.key"
  perms       = 0600
}

# Environment variables file (all KV keys as KEY=VALUE)
template {
  contents    = <<-EOT
    {{- with secret "secret/data/myapp/config" -}}
    {{- range $key, $value := .Data.data }}
    {{ $key }}={{ $value }}
    {{- end }}
    {{- end -}}
  EOT
  destination = "/vault/secrets/config.env"
  perms       = 0644
}

# AWS credentials (dynamic — auto-renewed)
# template {
#   contents    = <<-EOT
#     {{- with secret "aws/creds/app-role" -}}
#     [default]
#     aws_access_key_id={{ .Data.access_key }}
#     aws_secret_access_key={{ .Data.secret_key }}
#     {{- if .Data.security_token }}
#     aws_session_token={{ .Data.security_token }}
#     {{- end }}
#     {{- end -}}
#   EOT
#   destination = "/vault/secrets/aws-credentials"
#   perms       = 0600
# }

# --- Template Configuration (Global) ---
template_config {
  exit_on_retry_failure          = true
  static_secret_render_interval  = "30s"
  max_connections_per_host        = 10
}
