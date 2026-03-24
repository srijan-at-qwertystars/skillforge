---
name: consul-service-discovery
description: >
  Expert guidance for HashiCorp Consul service discovery, service mesh, and distributed configuration.
  Covers service registration (agent/catalog API), health checks (HTTP, TCP, gRPC, script, TTL),
  DNS interface, KV store, Consul Connect (mTLS, sidecar proxies, intentions), ACL system,
  gossip protocol, Raft consensus, multi-datacenter federation, consul-template, Consul on
  Kubernetes (Helm), watches, prepared queries, and sessions/locks.
  TRIGGERS: "Consul", "consul service", "service discovery with Consul", "Consul KV",
  "Consul Connect", "service mesh with Consul", "consul-template", "Consul intentions",
  "Consul health check", "Consul ACL", "Consul DNS", "Consul catalog", "consul agent",
  "Consul federation", "Consul prepared query", "Consul session", "Consul watch".
  NOT for etcd, ZooKeeper, Eureka, Istio without Consul, or general DNS/load balancing
  without Consul context.
---

# Consul Service Discovery & Service Mesh

## Architecture

Consul uses a client-server model. **Servers** (3 or 5) participate in Raft consensus, store state, and replicate data. **Clients** run on every node, forward RPCs to servers, and participate in LAN gossip (Serf). Each datacenter has its own cluster; cross-DC uses WAN gossip.

**Ports:** 8500 (HTTP), 8501 (HTTPS), 8600 (DNS), 8301 (LAN Serf), 8302 (WAN Serf), 8300 (RPC), 21000-21255 (sidecar proxies).

## 1. Service Registration

### Agent API (dynamic services)
```bash
curl -X PUT http://localhost:8500/v1/agent/service/register -d '{
  "ID": "web-1", "Name": "web", "Tags": ["primary","v2"],
  "Address": "10.0.1.10", "Port": 8080,
  "Meta": {"version": "2.1.0"},
  "Check": {"HTTP": "http://10.0.1.10:8080/health", "Interval": "10s", "Timeout": "3s"}
}'
# Deregister
curl -X PUT http://localhost:8500/v1/agent/service/deregister/web-1
```

### Catalog API (external services without agent)
```bash
curl -X PUT http://localhost:8500/v1/catalog/register -d '{
  "Datacenter": "dc1", "Node": "ext-db", "Address": "10.0.2.50",
  "Service": {"ID": "postgres-ext", "Service": "postgres", "Port": 5432}
}'
```

### Config File (static, reload with `consul reload` or SIGHUP)
```hcl
service {
  name = "web"
  port = 8080
  tags = ["primary"]
  check { http = "http://localhost:8080/health"; interval = "10s" }
}
```

## 2. Health Checks

| Type | Config Field | Use Case |
|------|-------------|----------|
| HTTP | `HTTP` | REST endpoints returning 2xx |
| TCP | `TCP` | Port connectivity |
| gRPC | `GRPC` | gRPC health protocol (`host:port/service`) |
| Script | `Args` | Custom scripts, exit 0=pass/1=warn/2=fail |
| TTL | `TTL` | App heartbeats via `PUT /v1/agent/check/pass/:id` |

```bash
# TTL: register, then heartbeat periodically
curl -X PUT http://localhost:8500/v1/agent/check/register -d \
  '{"Name":"app-ttl","ServiceID":"web-1","TTL":"30s"}'
curl -X PUT http://localhost:8500/v1/agent/check/pass/app-ttl
```

## 3. DNS Interface

Format: `<tag>.<service>.service[.<dc>].consul`. Serves on port 8600.

```bash
dig @127.0.0.1 -p 8600 web.service.consul SRV      # All healthy instances
dig @127.0.0.1 -p 8600 primary.web.service.consul   # Tag filter
dig @127.0.0.1 -p 8600 web.service.dc2.consul       # Cross-DC
dig @127.0.0.1 -p 8600 node1.node.consul             # Node lookup
```

Route `.consul` domain via dnsmasq, systemd-resolved, or iptables redirect.

## 4. KV Store

Hierarchical, strongly consistent. Supports CAS (Check-And-Set) via `ModifyIndex`.

```bash
curl -X PUT http://localhost:8500/v1/kv/config/db/host -d 'db.example.com'  # Write
curl -s http://localhost:8500/v1/kv/config/db/host?raw                      # Read raw
curl http://localhost:8500/v1/kv/config/?recurse                            # List prefix
curl -X PUT "http://localhost:8500/v1/kv/config/db/host?cas=42" -d 'new'    # CAS update
curl -X DELETE http://localhost:8500/v1/kv/config/db/host                   # Delete
```

## 5. Consul Connect (Service Mesh)

Provides service-to-service mTLS and identity-based authorization. Uses Envoy sidecar proxies.

### Service with Sidecar
```hcl
service {
  name = "web"
  port = 8080
  connect {
    sidecar_service {
      proxy {
        upstreams { destination_name = "api"; local_bind_port = 9191 }
      }
    }
  }
}
```
App connects to `localhost:9191` → encrypted mesh → `api` service.

```bash
consul connect envoy -sidecar-for web -admin-bind localhost:19000  # Start proxy
```

### Intentions (Service-to-Service AuthZ)
```bash
consul intention create -allow web api       # Allow
consul intention create -deny web database   # Deny
consul intention list
```

**L7 Intentions** (HTTP path/method filtering):
```hcl
Kind = "service-intentions"
Name = "api"
Sources = [{
  Name = "web"
  Permissions = [
    { Action = "allow", HTTP { PathPrefix = "/v2/", Methods = ["GET"] } },
    { Action = "deny",  HTTP { PathPrefix = "/admin" } }
  ]
}]
```
Apply: `consul config write intentions.hcl`

## 6. ACL System

```bash
consul acl bootstrap  # Run once, returns master token

consul acl policy create -name "web-policy" -rules @- <<'EOF'
service "web" { policy = "write" }
service_prefix "" { policy = "read" }
node_prefix "" { policy = "read" }
key_prefix "config/web/" { policy = "read" }
EOF

consul acl token create -description "web svc" -policy-name "web-policy"
```

Config: `acl { enabled = true; default_policy = "deny"; tokens { initial_management = "TOKEN" } }`

## 7. Gossip & Raft

**Gossip (Serf):** LAN pool for membership/failure detection; WAN pool for cross-DC server discovery. Encrypt: `consul keygen` → set `encrypt = "KEY"` in config.

**Raft:** Leader election among servers. Only leader processes writes. Check: `consul operator raft list-peers`. Use 3 or 5 servers. Autopilot handles dead server cleanup.

## 8. Multi-Datacenter Federation

Each DC has independent servers. WAN gossip connects them.

```bash
consul join -wan 10.1.0.1                                       # Join remote DC
curl http://localhost:8500/v1/catalog/service/web?dc=dc2         # Query remote DC
dig @127.0.0.1 -p 8600 web.service.dc2.consul                   # DNS cross-DC
```

**Mesh Gateways** route cross-DC traffic through firewalls (required for K8s federation):
```yaml
meshGateway: { enabled: true, replicas: 2 }
global: { federation: { enabled: true, createFederationSecret: true } }
```

## 9. consul-template

Renders templates from Consul/Vault data, executes commands on change.

```bash
consul-template -template "api.ctmpl:/etc/nginx/upstream.conf:nginx -s reload"
```

```nginx
# api.ctmpl
upstream api {
{{- range service "api|primary" }}
  server {{ .Address }}:{{ .Port }};
{{- end }}
}
```

KV template: `DB_HOST={{ key "config/db/host" }}`

## 10. Consul on Kubernetes (Helm)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install consul hashicorp/consul -n consul --create-namespace \
  --set server.replicas=3 \
  --set connectInject.enabled=true \
  --set global.acls.manageSystemACLs=true \
  --set global.tls.enabled=true \
  --set global.gossipEncryption.autoGenerate=true
```

**Sidecar injection** via pod annotations:
```yaml
metadata:
  annotations:
    consul.hashicorp.com/connect-inject: "true"
    consul.hashicorp.com/connect-service-upstreams: "api:9191"
```

**Service sync:** `syncCatalog: { enabled: true, toConsul: true, toK8S: true }`

## 11. Watches

React to Consul data changes (services, KV, checks, nodes, events).

```bash
consul watch -type=service -service=web /usr/local/bin/notify.sh
consul watch -type=keyprefix -prefix=config/ /usr/local/bin/reload.sh
```

Config-based with HTTP handler:
```hcl
watches = [{
  type = "service", service = "web", handler_type = "http"
  http_handler_config { path = "http://localhost:9090/callback"; method = "POST" }
}]
```

## 12. Prepared Queries

Advanced discovery with failover, nearest-DC routing, tag filtering.

```bash
curl -X POST http://localhost:8500/v1/query -d '{
  "Name": "web-nearest",
  "Service": {
    "Service": "web", "Tags": ["primary"], "OnlyPassing": true,
    "Failover": { "NearestN": 2, "Datacenters": ["dc2","dc3"] }
  }
}'
curl http://localhost:8500/v1/query/web-nearest/execute   # HTTP
dig @127.0.0.1 -p 8600 web-nearest.query.consul           # DNS
```

## 13. Sessions & Locks

Sessions enable distributed locking and leader election via KV.

```bash
# Create session
SID=$(curl -s -X PUT http://localhost:8500/v1/session/create \
  -d '{"Name":"my-lock","TTL":"30s","Behavior":"release"}' | jq -r .ID)
# Acquire lock (returns true/false)
curl -X PUT "http://localhost:8500/v1/kv/locks/resource?acquire=$SID" -d 'holder-1'
# Release
curl -X PUT "http://localhost:8500/v1/kv/locks/resource?release=$SID"
# Renew before TTL expires
curl -X PUT http://localhost:8500/v1/session/renew/$SID
```

CLI shorthand: `consul lock locks/deploy "deploy.sh"` — acquires lock, runs command, releases on exit.

Behaviors: `release` (default, frees locks on session invalidation), `delete` (removes locked keys).

---

## Examples

### Example 1: Register and discover a service

**Input:** "Register a payment service on port 3000 with an HTTP health check and find it."

**Output:**
```bash
curl -X PUT http://localhost:8500/v1/agent/service/register -d '{
  "Name": "payment", "Port": 3000,
  "Check": {"HTTP": "http://localhost:3000/healthz", "Interval": "10s"}
}'
dig @127.0.0.1 -p 8600 payment.service.consul SRV
curl http://localhost:8500/v1/health/service/payment?passing=true
```

### Example 2: Service mesh between frontend and backend

**Input:** "Connect frontend to backend through Consul Connect with intentions."

**Output:**
```hcl
# frontend.hcl
service {
  name = "frontend"
  port = 3000
  connect { sidecar_service {
    proxy { upstreams { destination_name = "backend"; local_bind_port = 5000 } }
  }}
}
```
```bash
consul connect envoy -sidecar-for frontend &
consul connect envoy -sidecar-for backend &
consul intention create -allow frontend backend
curl http://localhost:5000/api/data  # frontend reaches backend via mesh
```

### Example 3: Distributed lock for deploys

**Input:** "Use Consul to ensure only one node deploys at a time."

**Output:**
```bash
# Simple: CLI lock (blocks until acquired, releases on exit)
consul lock deploy/my-app "bash deploy.sh"

# API-based:
SID=$(curl -s -X PUT http://localhost:8500/v1/session/create \
  -d '{"Name":"deploy","TTL":"600s"}' | jq -r .ID)
if curl -s -X PUT "http://localhost:8500/v1/kv/deploy/lock?acquire=$SID" \
  -d "$(hostname)" | grep -q true; then
  bash deploy.sh
  curl -X PUT "http://localhost:8500/v1/kv/deploy/lock?release=$SID"
fi
curl -X PUT http://localhost:8500/v1/session/destroy/$SID
```

### Example 4: K8s deployment with Consul mesh

**Input:** "Deploy orders service on K8s connecting to inventory via Consul."

**Output:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: orders }
spec:
  replicas: 3
  selector: { matchLabels: { app: orders } }
  template:
    metadata:
      labels: { app: orders }
      annotations:
        consul.hashicorp.com/connect-inject: "true"
        consul.hashicorp.com/connect-service-upstreams: "inventory:6000"
    spec:
      containers:
      - name: orders
        image: myco/orders:latest
        env: [{ name: INVENTORY_URL, value: "http://localhost:6000" }]
```
