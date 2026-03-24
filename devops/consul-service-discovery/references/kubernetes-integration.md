# Consul Kubernetes Integration

## Table of Contents

- [Consul on Kubernetes Helm Chart](#consul-on-kubernetes-helm-chart)
  - [Installation](#installation)
  - [Helm Chart Architecture](#helm-chart-architecture)
  - [Key Helm Values](#key-helm-values)
  - [Upgrading Consul on K8s](#upgrading-consul-on-k8s)
- [Service Sync](#service-sync)
  - [Kubernetes to Consul](#kubernetes-to-consul)
  - [Consul to Kubernetes](#consul-to-kubernetes)
  - [Sync Configuration](#sync-configuration)
  - [Sync Filtering](#sync-filtering)
- [Connect Inject (Sidecar Injection)](#connect-inject-sidecar-injection)
  - [How Injection Works](#how-injection-works)
  - [Pod Annotations](#pod-annotations)
  - [Upstream Configuration](#upstream-configuration)
  - [Lifecycle and Init Containers](#lifecycle-and-init-containers)
- [Consul API Gateway on Kubernetes](#consul-api-gateway-on-kubernetes)
  - [Installation and Setup](#api-gateway-installation-and-setup)
  - [Gateway Configuration](#gateway-configuration)
  - [HTTP Routing](#http-routing)
  - [TLS Configuration](#api-gateway-tls-configuration)
- [Transparent Proxy](#transparent-proxy)
  - [How Transparent Proxy Works](#how-transparent-proxy-works)
  - [Configuration](#transparent-proxy-configuration)
  - [Excluding Traffic](#excluding-traffic)
  - [Troubleshooting Transparent Proxy](#troubleshooting-transparent-proxy)
- [Mesh Gateway for Multi-Cluster](#mesh-gateway-for-multi-cluster)
  - [Architecture](#mesh-gateway-architecture)
  - [Deploying Mesh Gateways](#deploying-mesh-gateways)
  - [WAN Federation via Mesh Gateways](#wan-federation-via-mesh-gateways)
  - [Cluster Peering via Mesh Gateways](#cluster-peering-via-mesh-gateways)
- [Custom Resource Definitions (CRDs)](#custom-resource-definitions-crds)
  - [ServiceDefaults](#servicedefaults)
  - [ServiceIntentions](#serviceintentions)
  - [ProxyDefaults](#proxydefaults)
  - [ServiceRouter](#servicerouter)
  - [ServiceSplitter](#servicesplitter)
  - [ServiceResolver](#serviceresolver)
  - [ExportedServices](#exportedservices)
  - [Mesh](#mesh-crd)
- [Vault Integration for Consul TLS](#vault-integration-for-consul-tls)
  - [Architecture](#vault-integration-architecture)
  - [Vault Setup for Consul](#vault-setup-for-consul)
  - [Helm Configuration for Vault TLS](#helm-configuration-for-vault-tls)
  - [Vault as Connect CA](#vault-as-connect-ca)
  - [Troubleshooting Vault Integration](#troubleshooting-vault-integration)

---

## Consul on Kubernetes Helm Chart

### Installation

```bash
# Add HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install with default values
helm install consul hashicorp/consul \
  -n consul --create-namespace \
  --version 1.3.0

# Install with custom values file
helm install consul hashicorp/consul \
  -n consul --create-namespace \
  -f consul-values.yaml

# Verify installation
kubectl -n consul get pods
kubectl -n consul get svc
```

### Helm Chart Architecture

The Helm chart deploys these components:

| Component | K8s Resource | Purpose |
|-----------|-------------|---------|
| Consul Server | StatefulSet | Raft consensus, state storage |
| Consul Client | DaemonSet (or none with Dataplane) | Local agent on each node |
| Connect Injector | Deployment | Mutating webhook for sidecar injection |
| Sync Catalog | Deployment | Bidirectional K8s ↔ Consul service sync |
| Mesh Gateway | Deployment | Cross-DC/peer traffic routing |
| API Gateway Controller | Deployment | Gateway API controller |
| Webhook Cert Manager | Deployment | Manages TLS certs for webhooks |

With **Consul Dataplane** (Helm v1.0+), client agents are replaced by `consul-dataplane` sidecars injected alongside Envoy.

### Key Helm Values

```yaml
global:
  name: consul
  datacenter: dc1
  image: "hashicorp/consul:1.17.0"
  imageConsulDataplane: "hashicorp/consul-dataplane:1.3.0"

  # TLS encryption for all Consul communication
  tls:
    enabled: true
    enableAutoEncrypt: true    # Auto-distribute certs to clients

  # Gossip encryption
  gossipEncryption:
    autoGenerate: true         # Auto-generate and distribute key

  # ACL system
  acls:
    manageSystemACLs: true     # Auto-bootstrap and configure ACLs

  # Metrics
  metrics:
    enabled: true
    enableAgentMetrics: true
    enableGatewayMetrics: true

server:
  replicas: 3                  # 3 or 5 for production
  storage: 10Gi
  storageClass: gp3
  resources:
    requests: { memory: "200Mi", cpu: "200m" }
    limits:   { memory: "512Mi", cpu: "500m" }

  # Anti-affinity to spread servers across nodes
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app: {{ template "consul.name" . }}
              component: server
          topologyKey: kubernetes.io/hostname

connectInject:
  enabled: true
  default: false               # Don't inject by default; use annotation
  transparentProxy:
    defaultEnabled: true       # Enable transparent proxy by default

syncCatalog:
  enabled: false               # Enable if you need K8s ↔ Consul sync

dns:
  enabled: true
  enableRedirection: true      # Auto-configure CoreDNS/kube-dns
```

### Upgrading Consul on K8s

```bash
# Check current version
helm list -n consul

# Review upgrade notes for the target version
helm show chart hashicorp/consul --version 1.3.0

# Dry run upgrade
helm upgrade consul hashicorp/consul \
  -n consul -f consul-values.yaml \
  --version 1.3.0 --dry-run

# Perform upgrade
helm upgrade consul hashicorp/consul \
  -n consul -f consul-values.yaml \
  --version 1.3.0

# Monitor rollout
kubectl -n consul rollout status statefulset/consul-server
kubectl -n consul get pods -w
```

---

## Service Sync

### Kubernetes to Consul

Registers K8s services in the Consul catalog so non-K8s services can discover them.

```yaml
# Helm values
syncCatalog:
  enabled: true
  toConsul: true
  toK8S: false    # One-way: K8s → Consul only

  # Only sync services with this annotation
  k8sAllowNamespaces: ["*"]     # Sync from all namespaces
  k8sDenyNamespaces: ["kube-system", "kube-public"]

  # Prefix for synced service names in Consul
  k8sPrefix: "k8s-"

  # Sync LoadBalancer/NodePort external IPs
  syncClusterIPServices: true
  nodePortSyncType: "ExternalFirst"  # ExternalFirst, InternalOnly, ExternalOnly
```

**Per-service annotation to control sync:**

```yaml
metadata:
  annotations:
    consul.hashicorp.com/service-sync: "true"          # Opt-in
    consul.hashicorp.com/service-name: "my-web"        # Override name in Consul
    consul.hashicorp.com/service-port: "http"           # Which port to register
    consul.hashicorp.com/service-tags: "v1,production"  # Tags in Consul
    consul.hashicorp.com/service-meta-version: "2.1"    # Metadata
```

### Consul to Kubernetes

Registers Consul services as K8s ExternalName services (or ClusterIP with Endpoints).

```yaml
syncCatalog:
  enabled: true
  toConsul: false
  toK8S: true

  # Only sync these Consul services to K8s
  consulNamespaces:
    consulDestinationNamespace: "default"
    mirroringK8S: true    # Mirror Consul namespaces to K8s namespaces

  # Prefix for K8s service names
  consulPrefix: ""

  k8sAllowNamespaces: ["default", "apps"]
  k8sDenyNamespaces: []
```

**Accessing Consul services from K8s:**

```bash
# Synced Consul service becomes a K8s service
kubectl get svc -l consul.hashicorp.com/service-sync=true

# Access via K8s DNS
curl http://my-consul-service.default.svc.cluster.local:8080
```

### Sync Configuration

**Bidirectional sync:**

```yaml
syncCatalog:
  enabled: true
  toConsul: true
  toK8S: true

  # Avoid sync loops — Consul adds a "k8s" tag to synced services
  # Services with "k8s" tag are not synced back to K8s
  addK8SNamespaceSuffix: true
```

### Sync Filtering

```yaml
syncCatalog:
  enabled: true

  # Namespace filtering
  k8sAllowNamespaces: ["production", "staging"]
  k8sDenyNamespaces: ["kube-system"]

  # Service name filtering (Consul → K8s)
  consulNodeName: "k8s-sync"

  # Only sync services with specific tags (Consul → K8s)
  consulK8STag: "k8s-sync"
```

---

## Connect Inject (Sidecar Injection)

### How Injection Works

1. Pod is created with annotation `consul.hashicorp.com/connect-inject: "true"`
2. Consul's mutating webhook intercepts the pod creation
3. Webhook adds init container (`consul-connect-inject-init`) and sidecar containers
4. Init container registers the service with Consul and configures iptables (transparent proxy)
5. Envoy sidecar starts and connects to Consul for xDS configuration
6. With Dataplane mode, `consul-dataplane` replaces the Consul client agent

### Pod Annotations

```yaml
metadata:
  annotations:
    # Core injection
    consul.hashicorp.com/connect-inject: "true"

    # Service configuration
    consul.hashicorp.com/connect-service: "web"           # Service name (default: pod name)
    consul.hashicorp.com/connect-service-port: "8080"      # Service port
    consul.hashicorp.com/service-tags: "v2,production"     # Service tags
    consul.hashicorp.com/service-meta-version: "2.0"       # Metadata
    consul.hashicorp.com/connect-service-protocol: "http"  # Protocol (http, http2, grpc, tcp)

    # Upstreams
    consul.hashicorp.com/connect-service-upstreams: "api:9191,database:5432"

    # Transparent proxy
    consul.hashicorp.com/transparent-proxy: "true"
    consul.hashicorp.com/transparent-proxy-exclude-inbound-ports: "9090"
    consul.hashicorp.com/transparent-proxy-exclude-outbound-ports: "443"
    consul.hashicorp.com/transparent-proxy-exclude-outbound-cidrs: "10.0.0.0/8"

    # Resource limits for sidecar
    consul.hashicorp.com/sidecar-proxy-cpu-request: "100m"
    consul.hashicorp.com/sidecar-proxy-cpu-limit: "500m"
    consul.hashicorp.com/sidecar-proxy-memory-request: "128Mi"
    consul.hashicorp.com/sidecar-proxy-memory-limit: "256Mi"

    # Metrics
    consul.hashicorp.com/enable-metrics: "true"
    consul.hashicorp.com/enable-metrics-merging: "true"
    consul.hashicorp.com/service-metrics-port: "9102"
    consul.hashicorp.com/service-metrics-path: "/metrics"

    # Envoy configuration
    consul.hashicorp.com/envoy-extra-args: "--concurrency 2"
    consul.hashicorp.com/envoy-cpu-request: "100m"
    consul.hashicorp.com/envoy-memory-request: "128Mi"
```

### Upstream Configuration

**Simple upstreams:**

```yaml
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api:9191"
  # App connects to localhost:9191 → mTLS → api service
```

**Multiple upstreams:**

```yaml
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api:9191,database:5432,cache:6379"
```

**Cross-datacenter upstream:**

```yaml
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api.dc2:9191"
```

**Peered upstream:**

```yaml
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api.svc.cluster-2.peer:9191"
```

**Prepared query upstream:**

```yaml
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api.query:9191"
```

### Lifecycle and Init Containers

The injection adds these containers:

1. **`consul-connect-inject-init`** (init container):
   - Registers service with Consul
   - Configures iptables rules (transparent proxy)
   - Waits for Envoy proxy to be ready

2. **`consul-dataplane`** (sidecar):
   - Manages Envoy lifecycle
   - Communicates with Consul servers via gRPC
   - Handles xDS configuration

3. **`envoy-sidecar`** (sidecar):
   - Envoy proxy handling mTLS and traffic routing

**Graceful shutdown:**

```yaml
annotations:
  consul.hashicorp.com/connect-inject: "true"
  consul.hashicorp.com/enable-sidecar-proxy-lifecycle: "true"
  consul.hashicorp.com/envoy-sidecar-proxy-lifecycle-default-enabled: "true"
  consul.hashicorp.com/envoy-sidecar-proxy-lifecycle-shutdown-grace-period-seconds: "5"
```

---

## Consul API Gateway on Kubernetes

### API Gateway Installation and Setup

```yaml
# Helm values to enable API Gateway
apiGateway:
  enabled: true
  image: "hashicorp/consul-api-gateway-controller:0.5.0"

  managedGatewayClass:
    serviceType: LoadBalancer

  resources:
    requests: { memory: "100Mi", cpu: "100m" }
    limits:   { memory: "200Mi", cpu: "200m" }
```

```bash
# Install/upgrade with API Gateway enabled
helm upgrade consul hashicorp/consul -n consul -f consul-values.yaml

# Verify GatewayClass is available
kubectl get gatewayclass
```

### Gateway Configuration

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: api-gateway
  namespace: consul
spec:
  gatewayClassName: consul
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All

    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: gateway-tls-cert
            namespace: consul
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
```

### HTTP Routing

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: app-routes
  namespace: default
spec:
  parentRefs:
    - name: api-gateway
      namespace: consul
  hostnames:
    - "app.example.com"
  rules:
    # Path-based routing
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1
      backendRefs:
        - name: api-v1
          port: 8080

    # Header-based routing
    - matches:
        - headers:
            - type: Exact
              name: x-version
              value: "2"
      backendRefs:
        - name: api-v2
          port: 8080

    # Weighted routing (canary)
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: web-stable
          port: 8080
          weight: 90
        - name: web-canary
          port: 8080
          weight: 10

    # URL rewrite
    - matches:
        - path:
            type: PathPrefix
            value: /old-api
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /api/v1
      backendRefs:
        - name: api-v1
          port: 8080
```

### API Gateway TLS Configuration

```yaml
# Create TLS secret
apiVersion: v1
kind: Secret
metadata:
  name: gateway-tls-cert
  namespace: consul
type: kubernetes.io/tls
data:
  tls.crt: <base64-cert>
  tls.key: <base64-key>

---
# Reference in Gateway listener
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: api-gateway
spec:
  gatewayClassName: consul
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: gateway-tls-cert
```

---

## Transparent Proxy

### How Transparent Proxy Works

Transparent proxy redirects all outbound traffic through the Envoy sidecar using iptables rules. Applications don't need to be configured to use `localhost:<port>` for upstreams — they can use Consul DNS names or KubeDNS directly.

**Traffic flow:**
1. App sends request to `api.default.svc.cluster.local:8080`
2. iptables redirects to Envoy's outbound listener (port 15001)
3. Envoy resolves the destination via Consul's service catalog
4. Envoy routes through mTLS to the destination's sidecar

### Transparent Proxy Configuration

**Global default (Helm):**

```yaml
connectInject:
  enabled: true
  transparentProxy:
    defaultEnabled: true
    defaultOverwriteProbes: true   # Redirect health check probes through proxy
```

**Per-pod annotation:**

```yaml
metadata:
  annotations:
    consul.hashicorp.com/connect-inject: "true"
    consul.hashicorp.com/transparent-proxy: "true"
```

**With transparent proxy, no upstream annotations are needed:**

```yaml
# Without transparent proxy (explicit upstreams):
annotations:
  consul.hashicorp.com/connect-service-upstreams: "api:9191"
# App must connect to localhost:9191

# With transparent proxy:
annotations:
  consul.hashicorp.com/transparent-proxy: "true"
# App connects directly to api.default.svc.cluster.local:8080
# Traffic is automatically routed through the mesh
```

### Excluding Traffic

Some traffic should bypass the proxy (e.g., metadata endpoints, external services).

```yaml
annotations:
  # Exclude specific outbound ports
  consul.hashicorp.com/transparent-proxy-exclude-outbound-ports: "443,8443"

  # Exclude specific outbound CIDRs
  consul.hashicorp.com/transparent-proxy-exclude-outbound-cidrs: "169.254.169.254/32,10.0.0.0/8"

  # Exclude specific inbound ports
  consul.hashicorp.com/transparent-proxy-exclude-inbound-ports: "9090,8081"

  # Exclude specific UIDs (traffic from these users bypasses proxy)
  consul.hashicorp.com/transparent-proxy-exclude-uids: "1000,1001"
```

### Troubleshooting Transparent Proxy

```bash
# Check iptables rules in the pod
kubectl exec -it <pod> -c consul-dataplane -- iptables -t nat -L -n -v

# Verify Envoy has the correct listeners
kubectl exec -it <pod> -c envoy-sidecar -- curl -s localhost:19000/listeners

# Check Envoy clusters for the destination
kubectl exec -it <pod> -c envoy-sidecar -- curl -s localhost:19000/clusters | grep <dest-svc>

# Check if destination service exists in Consul
kubectl exec -it <pod> -c consul-dataplane -- \
  curl -s http://consul-server.consul:8500/v1/catalog/service/<dest-svc>

# DNS resolution test
kubectl exec -it <pod> -- nslookup api.default.svc.cluster.local

# Common issues:
# 1. "No healthy upstream" — destination service not registered or unhealthy
# 2. "Connection refused" — iptables rules not set up; check init container logs
# 3. "Permission denied" — intentions blocking the connection
kubectl logs <pod> -c consul-connect-inject-init
```

---

## Mesh Gateway for Multi-Cluster

### Mesh Gateway Architecture

Mesh gateways are dedicated Envoy proxies that route cross-datacenter or cross-peer traffic. They allow clusters to communicate without direct pod-to-pod network connectivity.

**Traffic modes:**

| Mode | Description |
|------|-------------|
| `local` | Traffic exits through the local mesh gateway |
| `remote` | Traffic enters through the remote mesh gateway |
| `none` | Direct pod-to-pod (requires network connectivity) |

### Deploying Mesh Gateways

```yaml
# Helm values
meshGateway:
  enabled: true
  replicas: 2

  service:
    type: LoadBalancer
    # For AWS
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"

  resources:
    requests: { memory: "128Mi", cpu: "250m" }
    limits:   { memory: "256Mi", cpu: "500m" }

  # WAN address (must be reachable from other clusters)
  wanAddress:
    source: Service      # Use Service LoadBalancer IP
    port: 443
```

```bash
# Verify mesh gateway is running
kubectl -n consul get pods -l component=mesh-gateway
kubectl -n consul get svc consul-mesh-gateway

# Check mesh gateway registration in Consul
consul catalog services | grep mesh-gateway
```

### WAN Federation via Mesh Gateways

**Primary datacenter (dc1):**

```yaml
global:
  name: consul
  datacenter: dc1
  tls:
    enabled: true
  acls:
    manageSystemACLs: true

server:
  replicas: 3

meshGateway:
  enabled: true
  replicas: 2

connectInject:
  enabled: true

global:
  federation:
    enabled: true
    createFederationSecret: true   # Creates secret for secondary DCs
```

```bash
# After deploying dc1, export the federation secret
kubectl -n consul get secret consul-federation -o yaml > federation-secret.yaml
```

**Secondary datacenter (dc2):**

```yaml
global:
  name: consul
  datacenter: dc2
  tls:
    enabled: true
    caCert:
      secretName: consul-federation
      secretKey: caCert
    caKey:
      secretName: consul-federation
      secretKey: caKey
  acls:
    manageSystemACLs: true
    replicationToken:
      secretName: consul-federation
      secretKey: replicationToken

server:
  replicas: 3
  extraVolumes:
    - type: secret
      name: consul-federation
      items:
        - key: serverConfigJSON
          path: config.json
      load: true

meshGateway:
  enabled: true
  replicas: 2

connectInject:
  enabled: true
```

```bash
# Apply federation secret to dc2, then install Consul
kubectl -n consul apply -f federation-secret.yaml
helm install consul hashicorp/consul -n consul -f dc2-values.yaml
```

### Cluster Peering via Mesh Gateways

```yaml
# Both clusters need mesh gateways and peering through mesh gateways enabled
meshGateway:
  enabled: true
  replicas: 2

# Enable peering
global:
  peering:
    enabled: true

# Route peering traffic through mesh gateways
# Apply this Mesh config entry:
```

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: Mesh
metadata:
  name: mesh
  namespace: consul
spec:
  peering:
    peerThroughMeshGateways: true
```

```bash
# Generate peering token on cluster-1
kubectl -n consul exec consul-server-0 -- \
  consul peering generate-token -name cluster-2

# Establish peering on cluster-2
kubectl -n consul exec consul-server-0 -- \
  consul peering establish -name cluster-1 -peering-token <TOKEN>
```

---

## Custom Resource Definitions (CRDs)

Consul on K8s provides CRDs to manage config entries declaratively.

### ServiceDefaults

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: api
  namespace: default
spec:
  protocol: http

  # Mesh gateway mode for this service
  meshGateway:
    mode: local

  # Upstream configuration
  upstreamConfig:
    defaults:
      limits:
        maxConnections: 1024
        maxPendingRequests: 512
      passiveHealthCheck:
        interval: 30s
        maxFailures: 5

    overrides:
      - name: database
        connectTimeoutMs: 10000
        limits:
          maxConnections: 100

  # Expose paths through the proxy (for health checks, metrics)
  expose:
    checks: true
    paths:
      - path: /metrics
        protocol: http
        localPathPort: 9102
        listenerPort: 20200
```

### ServiceIntentions

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: api-intentions
  namespace: default
spec:
  destination:
    name: api
  sources:
    # L7 permissions (requires protocol = http in ServiceDefaults)
    - name: web
      permissions:
        - action: allow
          http:
            pathPrefix: /api/v2/
            methods: ["GET", "POST"]
        - action: allow
          http:
            pathExact: /health
            methods: ["GET"]
        - action: deny
          http:
            pathPrefix: /admin

    # L4 allow
    - name: monitoring
      action: allow

    # Deny all others
    - name: "*"
      action: deny
```

### ProxyDefaults

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global
  namespace: consul
spec:
  config:
    protocol: http
    local_connect_timeout_ms: 5000
    handshake_timeout_ms: 10000

  meshGateway:
    mode: local

  expose:
    checks: true

  transparentProxy:
    outboundListenerPort: 15001
```

### ServiceRouter

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceRouter
metadata:
  name: api
  namespace: default
spec:
  routes:
    - match:
        http:
          pathPrefix: /api/v2
      destination:
        service: api-v2

    - match:
        http:
          header:
            - name: x-canary
              exact: "true"
      destination:
        service: api
        serviceSubset: canary

    - match:
        http:
          pathPrefix: /
      destination:
        service: api
        requestTimeout: 30s
        numRetries: 3
```

### ServiceSplitter

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceSplitter
metadata:
  name: api
  namespace: default
spec:
  splits:
    - weight: 90
      service: api
      serviceSubset: stable
    - weight: 10
      service: api
      serviceSubset: canary
```

### ServiceResolver

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceResolver
metadata:
  name: api
  namespace: default
spec:
  defaultSubset: stable
  subsets:
    stable:
      filter: "Service.Meta.version == v1"
    canary:
      filter: "Service.Meta.version == v2"
  connectTimeout: 15s

  failover:
    "*":
      datacenters: ["dc2", "dc3"]

  loadBalancer:
    policy: least_request
    leastRequestConfig:
      choiceCount: 3
```

### ExportedServices

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ExportedServices
metadata:
  name: default
  namespace: consul
spec:
  services:
    - name: api
      consumers:
        - peer: cluster-2
    - name: database
      consumers:
        - peer: cluster-2
        - partition: team-frontend
```

### Mesh CRD

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: Mesh
metadata:
  name: mesh
  namespace: consul
spec:
  # Route peering traffic through mesh gateways
  peering:
    peerThroughMeshGateways: true

  # Allow/deny traffic to non-mesh destinations
  transparentProxy:
    meshDestinationsOnly: false

  # TLS configuration
  tls:
    incoming:
      tlsMinVersion: TLSv1_2
      cipherSuites:
        - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    outgoing:
      tlsMinVersion: TLSv1_2
```

---

## Vault Integration for Consul TLS

### Vault Integration Architecture

Vault can manage all TLS certificates for Consul:
1. **Server TLS**: Certificates for Consul server RPC and HTTP/gRPC
2. **Gossip encryption key**: Stored in Vault KV
3. **Connect CA**: Vault PKI backend as the Connect certificate authority
4. **ACL bootstrap token**: Stored in Vault KV

### Vault Setup for Consul

```bash
# Enable PKI secrets engine for Consul server TLS
vault secrets enable -path=consul/pki pki
vault secrets tune -max-lease-ttl=87600h consul/pki

# Generate root CA
vault write consul/pki/root/generate/internal \
  common_name="Consul CA" \
  ttl=87600h

# Create PKI role for Consul servers
vault write consul/pki/roles/consul-server \
  allowed_domains="dc1.consul,consul-server,consul-server.consul,consul-server.consul.svc" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_localhost=true \
  generate_lease=true \
  max_ttl=720h

# Store gossip encryption key in Vault KV
vault secrets enable -path=consul/data kv-v2
GOSSIP_KEY=$(consul keygen)
vault kv put consul/data/secret/gossip key="$GOSSIP_KEY"

# Create Vault policy for Consul
vault policy write consul-server - <<'EOF'
path "consul/pki/issue/consul-server" {
  capabilities = ["create", "update"]
}
path "consul/pki/cert/ca" {
  capabilities = ["read"]
}
path "consul/data/data/secret/gossip" {
  capabilities = ["read"]
}
EOF

# Enable Kubernetes auth method
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_HOST"

vault write auth/kubernetes/role/consul-server \
  bound_service_account_names=consul-server \
  bound_service_account_namespaces=consul \
  policies=consul-server \
  ttl=1h
```

### Helm Configuration for Vault TLS

```yaml
global:
  secretsBackend:
    vault:
      enabled: true
      consulServerRole: consul-server
      consulClientRole: consul-client
      consulCARole: consul-ca
      connectCA:
        address: https://vault.vault.svc:8200
        rootPKIPath: connect-root/
        intermediatePKIPath: connect-intermediate/
      ca:
        secretName: vault-ca-cert   # Vault's own CA cert

  tls:
    enabled: true
    enableAutoEncrypt: true
    serverAdditionalDNSSANs:
      - "consul-server.consul.svc"
    serverAdditionalIPSANs:
      - "127.0.0.1"

  # Gossip key from Vault
  gossipEncryption:
    secretName: consul/data/secret/gossip
    secretKey: key

server:
  serverCert:
    secretName: consul/pki/issue/consul-server

  # Vault annotations for server pods
  extraLabels:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "consul-server"
```

### Vault as Connect CA

```yaml
# Helm values
global:
  secretsBackend:
    vault:
      enabled: true
      connectCA:
        address: https://vault.vault.svc:8200
        authMethodPath: kubernetes
        rootPKIPath: connect-root/
        intermediatePKIPath: connect-intermediate/
        additionalConfig: |
          {
            "leaf_cert_ttl": "72h",
            "rotation_period": "2160h",
            "intermediate_cert_ttl": "8760h",
            "private_key_type": "ec",
            "private_key_bits": 256
          }
```

```bash
# Vault setup for Connect CA
vault secrets enable -path=connect-root pki
vault secrets tune -max-lease-ttl=87600h connect-root
vault write connect-root/root/generate/internal \
  common_name="Consul Connect Root CA" \
  ttl=87600h

vault secrets enable -path=connect-intermediate pki
vault secrets tune -max-lease-ttl=8760h connect-intermediate

# Policy for Connect CA
vault policy write consul-connect-ca - <<'EOF'
path "connect-root/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "connect-intermediate/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
EOF
```

### Troubleshooting Vault Integration

```bash
# Check Vault agent injector logs
kubectl -n vault logs -l app.kubernetes.io/name=vault-agent-injector

# Check Vault agent sidecar logs in Consul server pod
kubectl -n consul logs consul-server-0 -c vault-agent

# Verify Vault auth
kubectl -n consul exec consul-server-0 -c vault-agent -- \
  vault token lookup

# Check certificate from Vault
vault read consul/pki/cert/ca
vault write consul/pki/issue/consul-server \
  common_name="server.dc1.consul" \
  ttl=720h

# Common issues:
# 1. "permission denied" — Vault policy doesn't grant access
# 2. "no Vault token" — K8s auth method not configured
# 3. "certificate has expired" — Vault lease not renewed; check vault-agent
# 4. "x509: certificate signed by unknown authority" — Vault CA cert not trusted
```
