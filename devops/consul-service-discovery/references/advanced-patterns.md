# Consul Advanced Patterns

## Table of Contents

- [Consul Connect Deep Dive](#consul-connect-deep-dive)
  - [Envoy Sidecar Proxy Architecture](#envoy-sidecar-proxy-architecture)
  - [Sidecar Lifecycle and Configuration](#sidecar-lifecycle-and-configuration)
  - [L7 Traffic Management](#l7-traffic-management)
  - [Intentions with L7 Permissions](#intentions-with-l7-permissions)
- [Consul Dataplane](#consul-dataplane)
  - [Architecture](#dataplane-architecture)
  - [Deployment](#dataplane-deployment)
  - [Migration from Client Agents](#migration-from-client-agents)
- [API Gateway](#api-gateway)
  - [Architecture and Components](#api-gateway-architecture-and-components)
  - [Configuration](#api-gateway-configuration)
  - [Route Types](#api-gateway-route-types)
  - [TLS and Authentication](#tls-and-authentication)
- [Cluster Peering](#cluster-peering)
  - [Peering vs WAN Federation](#peering-vs-wan-federation)
  - [Establishing a Peering Connection](#establishing-a-peering-connection)
  - [Exporting Services](#exporting-services)
  - [Peering over Mesh Gateways](#peering-over-mesh-gateways)
- [Admin Partitions](#admin-partitions)
  - [Partition Architecture](#partition-architecture)
  - [Creating and Managing Partitions](#creating-and-managing-partitions)
  - [Cross-Partition Networking](#cross-partition-networking)
- [Network Segments](#network-segments)
  - [Segment Configuration](#segment-configuration)
  - [Use Cases](#network-segment-use-cases)
- [Consul DNS Forwarding](#consul-dns-forwarding)
  - [systemd-resolved](#systemd-resolved)
  - [dnsmasq](#dnsmasq)
  - [CoreDNS](#coredns)
  - [iptables Redirect](#iptables-redirect)
- [Watches and Blocking Queries](#watches-and-blocking-queries)
  - [Blocking Queries (Long Poll)](#blocking-queries-long-poll)
  - [Watch Types](#watch-types)
  - [Programmatic Watches](#programmatic-watches)
- [Snapshot Agent](#snapshot-agent)
  - [Configuration](#snapshot-agent-configuration)
  - [Storage Backends](#storage-backends)
  - [Disaster Recovery Workflow](#disaster-recovery-workflow)

---

## Consul Connect Deep Dive

### Envoy Sidecar Proxy Architecture

Consul Connect uses Envoy as its data plane proxy. Each service instance gets a co-located Envoy sidecar that handles mTLS termination, authorization, and traffic routing.

**How the sidecar bootstraps:**

1. `consul connect envoy` generates Envoy bootstrap config
2. Envoy connects to the local Consul agent's gRPC port (8502) for xDS
3. Consul serves as the xDS control plane (CDS, EDS, LDS, RDS)
4. Envoy receives cluster, endpoint, listener, and route configuration
5. Certificates are provisioned through Consul's built-in CA or Vault

**Bootstrap customization:**

```bash
# Generate bootstrap config without starting Envoy
consul connect envoy -sidecar-for web -bootstrap > envoy-bootstrap.json

# Custom admin bind and stats port
consul connect envoy -sidecar-for web \
  -admin-bind 127.0.0.1:19000 \
  -grpc-addr localhost:8502 \
  -envoy-version 1.28.0

# With custom Envoy binary
consul connect envoy -sidecar-for web \
  -envoy-binary /usr/local/bin/envoy
```

**Envoy overrides via `envoy_extensions`:**

```hcl
Kind = "service-defaults"
Name = "web"
Protocol = "http"

EnvoyExtensions = [
  {
    Name = "builtin/lua"
    Arguments = {
      ProxyType = "connect-proxy"
      Listener  = "inbound"
      Script    = <<-EOF
        function envoy_on_request(handle)
          handle:headers():add("x-custom-header", "value")
        end
      EOF
    }
  }
]
```

**Key Envoy admin endpoints** (on admin-bind port, default 19000):

```bash
curl localhost:19000/clusters      # Upstream clusters and endpoints
curl localhost:19000/config_dump   # Full xDS config
curl localhost:19000/stats         # Metrics
curl localhost:19000/listeners     # Active listeners
curl localhost:19000/ready         # Readiness check
```

### Sidecar Lifecycle and Configuration

**Proxy defaults** control global sidecar behavior:

```hcl
Kind = "proxy-defaults"
Name = "global"

Config {
  protocol                 = "http"
  local_connect_timeout_ms = 5000
  handshake_timeout_ms     = 10000
  local_request_timeout_ms = 30000
}

MeshGateway {
  Mode = "local"  # "local", "remote", "none"
}

TransparentProxy {
  OutboundListenerPort = 15001
}

Expose {
  Checks = true   # Expose health check paths through proxy
  Paths  = [
    { Path = "/metrics", Protocol = "http", LocalPathPort = 9102, ListenerPort = 20200 }
  ]
}
```

**Per-service defaults:**

```hcl
Kind     = "service-defaults"
Name     = "api"
Protocol = "http"

UpstreamConfig {
  Defaults {
    MeshGateway { Mode = "local" }
    Limits {
      MaxConnections        = 1024
      MaxPendingRequests     = 512
      MaxConcurrentRequests  = 256
    }
    PassiveHealthCheck {
      Interval     = "30s"
      MaxFailures  = 5
      MaxEjectionPercent = 50
    }
  }
  Overrides = [
    {
      Name = "database"
      ConnectTimeoutMs = 10000
      Limits { MaxConnections = 100 }
    }
  ]
}
```

### L7 Traffic Management

L7 traffic management requires `protocol = "http"` (or `http2`/`grpc`) in service-defaults.

**Service Router** — split traffic by HTTP path, header, or query param:

```hcl
Kind = "service-router"
Name = "api"

Routes = [
  {
    Match { HTTP { PathPrefix = "/v2/" } }
    Destination { Service = "api-v2" }
  },
  {
    Match {
      HTTP {
        Header = [{ Name = "x-canary", Exact = "true" }]
      }
    }
    Destination {
      Service       = "api"
      ServiceSubset = "canary"
    }
  },
  {
    Match { HTTP { PathPrefix = "/admin" } }
    Destination {
      Service           = "api"
      PrefixRewrite     = "/"
      RequestTimeout    = "60s"
      NumRetries        = 3
      RetryOnStatusCodes = [503, 502]
    }
  }
]
```

**Service Splitter** — percentage-based traffic splitting (canary / blue-green):

```hcl
Kind = "service-splitter"
Name = "api"

Splits = [
  { Weight = 90, Service = "api", ServiceSubset = "stable" },
  { Weight = 10, Service = "api", ServiceSubset = "canary" }
]
```

**Service Resolver** — subsets, failover, redirect:

```hcl
Kind = "service-resolver"
Name = "api"

DefaultSubset = "stable"

Subsets = {
  stable = { Filter = "Service.Meta.version == 1.0" }
  canary = { Filter = "Service.Meta.version == 2.0" }
}

Failover = {
  "*" = {
    Datacenters = ["dc2", "dc3"]
  }
}

ConnectTimeout = "15s"

LoadBalancer {
  Policy = "least_request"
  LeastRequestConfig { ChoiceCount = 3 }
}
```

**Traffic flow:** Router → Splitter → Resolver → Envoy clusters

### Intentions with L7 Permissions

L7 intentions provide fine-grained HTTP-based authorization on top of identity-based mTLS.

```hcl
Kind = "service-intentions"
Name = "api"

Sources = [
  {
    Name = "web"
    Permissions = [
      {
        Action = "allow"
        HTTP {
          PathPrefix = "/api/v2/"
          Methods    = ["GET", "POST"]
          Header = [
            { Name = "x-api-version", Exact = "2" }
          ]
        }
      },
      {
        Action = "allow"
        HTTP {
          PathExact = "/health"
          Methods   = ["GET"]
        }
      },
      {
        Action = "deny"
        HTTP {
          PathPrefix = "/admin"
        }
      }
    ]
  },
  {
    Name        = "monitoring"
    Action      = "allow"
    Description = "L4 allow — monitoring can reach any path"
  },
  {
    Name   = "*"
    Action = "deny"
  }
]
```

**Evaluation order for L7 permissions:**
1. Permissions are evaluated top-to-bottom within a source
2. First matching permission wins
3. If no permission matches, the connection is **denied** (implicit deny for L7 sources with permissions)
4. L4 intentions (Action at the source level) are evaluated separately

**JWT-based authorization (Consul 1.17+):**

```hcl
Kind = "service-intentions"
Name = "api"
JWT = {
  Providers = [
    {
      Name = "okta"
      VerifyClaims = [
        { Path = ["aud"], Value = "api.example.com" },
        { Path = ["roles"], Value = "admin" }
      ]
    }
  ]
}
Sources = [
  { Name = "*", Action = "allow" }
]
```

---

## Consul Dataplane

### Dataplane Architecture

Consul Dataplane replaces client agents with a lightweight process that manages the Envoy proxy directly. Instead of each node running a Consul client agent, `consul-dataplane` communicates directly with Consul servers via gRPC.

**Benefits:**
- Reduced resource overhead (no gossip pool per node)
- Simplified operations (fewer processes to manage)
- Better suited for ephemeral workloads (containers, serverless)
- Required for Consul on HCP (HashiCorp Cloud Platform)

**Architecture changes:**
- No local Consul agent — dataplane talks to servers directly
- xDS proxying moves from local agent to `consul-dataplane`
- ACL tokens are provided directly to dataplane
- Health checks run within the Envoy proxy (not agent)

### Dataplane Deployment

```bash
consul-dataplane \
  -addresses "consul-server.dc1.consul:8502" \
  -service-node-name "web-node" \
  -proxy-service-id "web-sidecar-proxy" \
  -ca-certs /certs/ca.pem \
  -login-bearer-token-path /var/run/secrets/consul/token \
  -tls-server-name server.dc1.consul \
  -envoy-concurrency 2
```

On Kubernetes, Consul Dataplane is deployed automatically when using Helm chart v1.0+ with:

```yaml
global:
  imageConsulDataplane: "hashicorp/consul-dataplane:1.3"
connectInject:
  enabled: true
```

### Migration from Client Agents

1. Upgrade Consul servers to 1.14+
2. Update Helm chart to v1.0+ (Kubernetes) or deploy consul-dataplane binary (VMs)
3. Service health checks move from agent to Envoy-based checks
4. DNS queries route to Consul servers directly or via a DNS proxy
5. Remove client agent configuration and processes

---

## API Gateway

### API Gateway Architecture and Components

Consul API Gateway manages north-south traffic (external to mesh). It implements the Kubernetes Gateway API specification.

**Components:**
- **GatewayClass**: Defines the gateway controller (Consul)
- **Gateway**: Instance with listeners (ports, protocols, TLS)
- **HTTPRoute / TCPRoute**: Maps incoming requests to mesh services

### API Gateway Configuration

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: GatewayClass
metadata:
  name: consul
spec:
  controllerName: hashicorp.com/consul-api-gateway-controller

---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: api-gateway
  namespace: consul
spec:
  gatewayClassName: consul
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        certificateRefs:
          - name: api-gateway-cert
            namespace: consul
    - name: http
      protocol: HTTP
      port: 80
```

### API Gateway Route Types

**HTTP Route:**

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: api-routes
spec:
  parentRefs:
    - name: api-gateway
      namespace: consul
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: api-v1
          port: 8080
    - matches:
        - path:
            type: PathPrefix
            value: /api/v2
      backendRefs:
        - name: api-v2
          port: 8080
    - matches:
        - headers:
            - name: x-canary
              value: "true"
      backendRefs:
        - name: api-canary
          port: 8080
          weight: 100
```

**TCP Route:**

```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: db-route
spec:
  parentRefs:
    - name: api-gateway
  rules:
    - backendRefs:
        - name: database
          port: 5432
```

### TLS and Authentication

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-gateway-cert
  namespace: consul
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-cert>
  tls.key: <base64-encoded-key>
```

API Gateway supports JWT verification via `GatewayPolicy` (Consul CRD):

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: GatewayPolicy
metadata:
  name: jwt-auth
spec:
  targetRef:
    name: api-gateway
    kind: Gateway
    group: gateway.networking.k8s.io
  override:
    jwt:
      providers:
        - name: okta
          issuer: "https://example.okta.com"
          audiences: ["api.example.com"]
          jwksURI: "https://example.okta.com/.well-known/jwks.json"
```

---

## Cluster Peering

### Peering vs WAN Federation

| Feature | Cluster Peering | WAN Federation |
|---------|----------------|----------------|
| Topology | Any-to-any, independent | Hub-and-spoke, shared config |
| Gossip | No shared gossip pool | WAN gossip required |
| ACL system | Independent per cluster | Shared, primary DC required |
| Admin partitions | Supported (peer partitions) | Not supported |
| Trust model | Independent CAs, trust bundle exchange | Single shared CA |
| Config entries | Independent per cluster | Replicated from primary |
| Network requirement | Mesh gateways (no direct connectivity) | Direct server-to-server or mesh gateways |
| Best for | Multi-cloud, org boundaries, loose coupling | Tightly coupled DCs, single org |

### Establishing a Peering Connection

**Step 1: Generate peering token (acceptor cluster):**

```bash
# On cluster-1 (acceptor)
consul peering generate-token -name cluster-2 -server-external-addresses "1.2.3.4:8503"
# Returns a base64 token
```

**Step 2: Establish peering (dialer cluster):**

```bash
# On cluster-2 (dialer)
consul peering establish -name cluster-1 -peering-token <token-from-step-1>
```

**Step 3: Verify peering:**

```bash
consul peering list
consul peering read -name cluster-1
```

### Exporting Services

Services must be explicitly exported to peers:

```hcl
Kind = "exported-services"
Name = "default"

Services = [
  {
    Name = "api"
    Consumers = [
      { Peer = "cluster-2" }
    ]
  },
  {
    Name = "database"
    Consumers = [
      { Peer = "cluster-2" },
      { Peer = "cluster-3" }
    ]
  }
]
```

**Consuming peered services:**

```hcl
# In service config — upstream pointing to peered service
service {
  name = "web"
  connect {
    sidecar_service {
      proxy {
        upstreams {
          destination_name = "api"
          destination_peer = "cluster-1"
          local_bind_port  = 9191
        }
      }
    }
  }
}
```

DNS lookup for peered services: `api.service.<peer>.peer.consul`

### Peering over Mesh Gateways

For production, route peering traffic through mesh gateways to avoid direct connectivity:

```hcl
Kind = "mesh"
Peering {
  PeerThroughMeshGateways = true
}
```

Ensure mesh gateways are deployed and have WAN-reachable addresses.

---

## Admin Partitions

### Partition Architecture

Admin partitions (Enterprise/HCP) provide multi-tenancy within a single Consul cluster. Each partition has its own:
- Service catalog
- ACL namespace
- Config entries
- Health checks

The `default` partition always exists. Servers only exist in the `default` partition; clients can join any partition.

### Creating and Managing Partitions

```bash
# Create partition
consul partition create -name team-frontend -description "Frontend team services"
consul partition create -name team-backend

# List partitions
consul partition list

# Write to a partition
consul services register -partition team-frontend web.hcl
consul kv put -partition team-frontend config/key value
```

ACL policies can be scoped to partitions:

```hcl
partition "team-frontend" {
  service_prefix "" { policy = "read" }
  node_prefix "" { policy = "read" }
  namespace "default" {
    service "web" { policy = "write" }
  }
}
```

### Cross-Partition Networking

Services in different partitions communicate through **partition exports** and mesh gateways:

```hcl
Kind      = "exported-services"
Name      = "default"
Partition = "team-backend"

Services = [
  {
    Name = "api"
    Consumers = [
      { Partition = "team-frontend" }
    ]
  }
]
```

---

## Network Segments

### Segment Configuration

Network segments (Enterprise) allow agents to join separate LAN gossip pools within the same datacenter. Useful for network segmentation (DMZ, PCI zones).

**Server configuration:**

```hcl
segments = [
  {
    name       = "dmz"
    bind       = "10.0.2.1"
    port       = 8303
    advertise  = "10.0.2.1"
  },
  {
    name       = "pci"
    bind       = "10.0.3.1"
    port       = 8304
    advertise  = "10.0.3.1"
  }
]
```

**Client joining a segment:**

```hcl
segment = "dmz"
```

```bash
consul agent -segment dmz -join 10.0.2.1:8303
```

### Network Segment Use Cases

- **DMZ isolation**: Public-facing services in separate gossip pool
- **PCI compliance**: Cardholder data environment (CDE) in dedicated segment
- **Network partitions**: Reduce blast radius of gossip failures
- **Multi-tenant infrastructure**: Isolate tenant traffic at the gossip level

---

## Consul DNS Forwarding

### systemd-resolved

```ini
# /etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
Domains=~consul
```

```bash
sudo systemctl restart systemd-resolved
resolvectl status  # Verify consul domain routes
```

### dnsmasq

```ini
# /etc/dnsmasq.d/consul.conf
server=/consul/127.0.0.1#8600
strict-order
```

### CoreDNS

Commonly used in Kubernetes. Add to Corefile:

```
consul {
    forward . 10.96.0.10:8600 {   # Consul DNS service ClusterIP
        except cluster.local
    }
    cache 30
    errors
}
```

Or with the Consul Helm chart:

```yaml
dns:
  enabled: true
  enableRedirection: true   # Auto-configure CoreDNS/kube-dns
```

### iptables Redirect

Redirect port 53 queries for `.consul` to 8600:

```bash
iptables -t nat -A OUTPUT -d localhost -p udp -m udp --dport 53 \
  -j REDIRECT --to-ports 8600
iptables -t nat -A OUTPUT -d localhost -p tcp -m tcp --dport 53 \
  -j REDIRECT --to-ports 8600
```

---

## Watches and Blocking Queries

### Blocking Queries (Long Poll)

Consul supports blocking queries on most read endpoints. The client provides the last known `X-Consul-Index` and Consul holds the connection until data changes or the timeout expires.

```bash
# Initial query — note the X-Consul-Index header
INDEX=$(curl -s -D- http://localhost:8500/v1/health/service/web?passing=true \
  | grep X-Consul-Index | awk '{print $2}' | tr -d '\r')

# Blocking query — waits up to 5 minutes for changes
curl -s "http://localhost:8500/v1/health/service/web?passing=true&index=${INDEX}&wait=5m"
```

**Best practices:**
- Always use `wait` parameter (default 5m, max 10m)
- Add random jitter to avoid thundering herd
- Handle index reset (new index < old index) by resetting to 0
- Use `stale` mode for blocking queries on non-leader servers to reduce load

### Watch Types

| Type | Description | Key Parameters |
|------|-------------|----------------|
| `key` | Single KV key | `key` |
| `keyprefix` | KV prefix | `prefix` |
| `services` | All services list | — |
| `service` | Specific service instances | `service`, `tag`, `passingonly` |
| `checks` | Health checks | `service`, `state` |
| `nodes` | Catalog nodes | — |
| `event` | User events | `name` |

**Config-file watch with script handler:**

```hcl
watches = [
  {
    type    = "service"
    service = "web"
    args    = ["/usr/local/bin/update-lb.sh"]
  },
  {
    type   = "keyprefix"
    prefix = "config/global/"
    args   = ["/usr/local/bin/reload-config.sh"]
  },
  {
    type         = "checks"
    state        = "critical"
    handler_type = "http"
    http_handler_config {
      path   = "http://alerts.internal:9090/consul-alert"
      method = "POST"
      header = { "Authorization" = ["Bearer SECRET"] }
    }
  }
]
```

### Programmatic Watches

**Go SDK:**

```go
plan, _ := watch.Parse(map[string]interface{}{
    "type":    "service",
    "service": "web",
})
plan.HybridHandler = func(index watch.BlockingParamVal, result interface{}) {
    entries := result.([]*api.ServiceEntry)
    // Update load balancer config
}
go plan.Run("localhost:8500")
defer plan.Stop()
```

**Python (using requests with blocking queries):**

```python
import requests, time

index = "0"
while True:
    resp = requests.get(
        f"http://localhost:8500/v1/health/service/web?passing=true&index={index}&wait=60s"
    )
    new_index = resp.headers.get("X-Consul-Index", "0")
    if new_index != index:
        services = resp.json()
        update_upstream(services)
        index = new_index
    time.sleep(0.1)  # Brief pause between loops
```

---

## Snapshot Agent

### Snapshot Agent Configuration

The snapshot agent (Enterprise, or OSS via `consul snapshot save`) takes periodic snapshots of the Consul state.

**Manual snapshot (OSS):**

```bash
consul snapshot save backup-$(date +%Y%m%d-%H%M%S).snap
consul snapshot restore backup.snap   # Restore
consul snapshot inspect backup.snap   # Verify integrity
```

### Storage Backends

**Enterprise snapshot agent config:**

```hcl
snapshot_agent {
  interval = "1h"
  retain   = 72   # Keep 72 snapshots

  local_storage {
    path = "/opt/consul/snapshots"
  }

  aws_storage {
    s3_bucket          = "consul-snapshots"
    s3_region          = "us-east-1"
    s3_key_prefix      = "dc1/"
    s3_server_side_encryption = true
  }

  azure_blob_storage {
    container_name = "consul-snapshots"
    account_name   = "storageaccount"
    account_key    = "KEY"
  }

  google_storage {
    bucket = "consul-snapshots"
  }
}
```

### Disaster Recovery Workflow

1. **Take snapshot** on healthy cluster: `consul snapshot save pre-change.snap`
2. **Verify snapshot**: `consul snapshot inspect pre-change.snap`
3. **Transfer** snapshot to new/target cluster
4. **Restore**: `consul snapshot restore pre-change.snap`

**Caveats:**
- Snapshots include KV data, service catalog, ACLs, config entries, intentions
- Snapshots do NOT include Raft peer configuration (new cluster must be bootstrapped first)
- Restoring replaces ALL state — it's not a merge operation
- Ensure the restoring cluster has the same or newer Consul version
- ACL tokens in the snapshot must match or be re-bootstrapped
