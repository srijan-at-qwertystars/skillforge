# Annotated Service Definition with Connect Sidecar
#
# This file demonstrates a full service registration with all commonly used options.
# Place in Consul's config directory (e.g., /etc/consul.d/) and run `consul reload`.
#
# Reference: https://developer.hashicorp.com/consul/docs/services/configuration/services-configuration-reference

service {
  # --- Identity ---
  # Unique ID for this instance. Defaults to Name if not set.
  # Must be unique per agent. Use a suffix for multiple instances on one host.
  id   = "web-1"

  # Service name used for discovery. Multiple instances share the same name.
  name = "web"

  # Tags for filtering in DNS queries and catalog lookups.
  # DNS: <tag>.web.service.consul
  tags = ["primary", "v2"]

  # Metadata key-value pairs. Accessible via API and consul-template.
  meta = {
    version     = "2.1.0"
    environment = "production"
    team        = "frontend"
  }

  # --- Network ---
  # Address and port where the service listens.
  # Address defaults to the agent's address if not set.
  address = "10.0.1.10"
  port    = 8080

  # Enable tag override: allows catalog to override tags set here.
  # Useful when external systems manage tags (e.g., blue/green deploys).
  enable_tag_override = false

  # --- Health Checks ---
  # Multiple checks can be defined. Service is "passing" only when all pass.
  check {
    # Check ID (auto-generated if not set)
    id       = "web-http-check"
    name     = "HTTP Health Check"

    # HTTP check: GET request, 2xx = pass
    http     = "http://10.0.1.10:8080/health"
    method   = "GET"
    interval = "10s"
    timeout  = "3s"

    # TLS settings for HTTPS checks
    # tls_server_name       = "web.example.com"
    # tls_skip_verify       = false

    # Custom headers for the health check request
    header = {
      "User-Agent"    = ["Consul Health Check"]
      "Authorization" = ["Bearer health-check-token"]
    }

    # Deregister the service if critical for this duration.
    # Prevents stale entries from permanently unhealthy services.
    deregister_critical_service_after = "5m"

    # Notes visible in the UI
    notes = "HTTP check against /health endpoint"
  }

  # Additional check: TCP connectivity
  check {
    id       = "web-tcp-check"
    name     = "TCP Port Check"
    tcp      = "10.0.1.10:8080"
    interval = "30s"
    timeout  = "5s"
  }

  # --- Consul Connect (Service Mesh) ---
  connect {
    # Sidecar proxy configuration.
    # Consul will register a companion "web-sidecar-proxy" service.
    sidecar_service {
      # Sidecar listens on a dynamically assigned port (21000-21255 range).
      # Override with: port = 21000

      # Tags and meta for the sidecar proxy service itself
      tags = ["proxy"]

      proxy {
        # --- Upstreams ---
        # Define services this service connects to through the mesh.
        # Each upstream gets a local listener on localhost:<local_bind_port>.
        upstreams {
          # The destination service name in Consul
          destination_name = "api"

          # Local port the app uses to reach this upstream
          # App connects to localhost:9191 → mTLS → api service
          local_bind_port  = 9191

          # Mesh gateway mode for this upstream
          # "local" = route through local mesh gateway
          # "remote" = route through remote mesh gateway
          # "none" = direct connection
          mesh_gateway {
            mode = "local"
          }

          # Connection limits for this upstream
          config {
            limits {
              max_connections         = 1024
              max_pending_requests    = 512
              max_concurrent_requests = 256
            }
            connect_timeout_ms = 5000
            passive_health_check {
              interval     = "30s"
              max_failures = 5
            }
          }
        }

        # Additional upstream: database
        upstreams {
          destination_name = "postgres"
          local_bind_port  = 5432
        }

        # Cross-datacenter upstream
        # upstreams {
        #   destination_name = "auth"
        #   destination_datacenter = "dc2"
        #   local_bind_port  = 9292
        # }

        # Peered upstream (cluster peering)
        # upstreams {
        #   destination_name = "payments"
        #   destination_peer = "cluster-2"
        #   local_bind_port  = 9393
        # }

        # --- Expose Paths ---
        # Expose specific HTTP paths through the proxy without mTLS.
        # Useful for health checks, metrics, and readiness probes.
        expose {
          # Automatically expose all registered HTTP/gRPC health checks
          checks = true

          # Expose additional paths
          paths {
            path            = "/metrics"
            protocol        = "http"
            local_path_port = 9102  # Port where the app serves metrics
            listener_port   = 20200 # External port for scraping
          }
        }

        # --- Transparent Proxy ---
        # When enabled, all outbound traffic is routed through the proxy.
        # No explicit upstream configuration needed; use Consul DNS names.
        # transparent_proxy {
        #   outbound_listener_port = 15001
        # }

        # --- Local Service Configuration ---
        # Protocol for the local service (affects L7 features)
        config {
          protocol = "http"
        }
      }
    }
  }

  # --- Weights ---
  # Influence DNS round-robin and load balancing weight.
  weights {
    passing = 10  # Weight when healthy (default: 1)
    warning = 1   # Weight when in warning state (default: 1)
  }

  # --- Namespace and Partition (Enterprise) ---
  # namespace = "frontend"
  # partition = "team-a"

  # --- Token ---
  # ACL token for this service registration.
  # Alternatively, set via CONSUL_HTTP_TOKEN or agent default token.
  # token = "service-acl-token"
}
