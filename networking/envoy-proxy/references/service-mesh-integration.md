# Envoy Proxy — Service Mesh Integration

## Table of Contents

- [Envoy as Istio Sidecar](#envoy-as-istio-sidecar)
  - [Sidecar Injection and Architecture](#sidecar-injection-and-architecture)
  - [Istio xDS: Pilot/istiod to Envoy](#istio-xds-pilotistiod-to-envoy)
  - [EnvoyFilter CRD — Patching Generated Config](#envoyfilter-crd--patching-generated-config)
  - [Istio Traffic Policies → Envoy Config Mapping](#istio-traffic-policies--envoy-config-mapping)
  - [Debugging Istio Sidecar](#debugging-istio-sidecar)
- [Consul Connect Dataplane](#consul-connect-dataplane)
  - [Consul Envoy Integration](#consul-envoy-integration)
  - [Consul Intentions → Envoy RBAC](#consul-intentions--envoy-rbac)
  - [Consul Service Defaults and Proxy Config](#consul-service-defaults-and-proxy-config)
- [AWS App Mesh](#aws-app-mesh)
  - [App Mesh Architecture](#app-mesh-architecture)
  - [Virtual Node and Virtual Service](#virtual-node-and-virtual-service)
  - [App Mesh Envoy Config](#app-mesh-envoy-config)
- [xDS Control Planes](#xds-control-planes)
  - [go-control-plane](#go-control-plane)
  - [java-control-plane](#java-control-plane)
  - [Building a Custom Control Plane](#building-a-custom-control-plane)
- [Envoy Gateway](#envoy-gateway)
  - [Architecture Overview](#architecture-overview)
  - [Gateway API Resources](#gateway-api-resources)
  - [Envoy Gateway Configuration](#envoy-gateway-configuration)
  - [Advanced Envoy Gateway Patterns](#advanced-envoy-gateway-patterns)
- [Gateway API Support](#gateway-api-support)
  - [Gateway API Concepts](#gateway-api-concepts)
  - [HTTPRoute Configuration](#httproute-configuration)
  - [GRPCRoute and TLSRoute](#grpcroute-and-tlsroute)
  - [BackendTLSPolicy](#backendtlspolicy)

---

## Envoy as Istio Sidecar

### Sidecar Injection and Architecture

In Istio's sidecar model, every pod gets an Envoy proxy injected as a sidecar container. Traffic is transparently redirected through Envoy via iptables rules.

```
┌─────────────────────────────────────────────────────┐
│                     Kubernetes Pod                   │
│                                                     │
│  ┌─────────────┐    iptables    ┌────────────────┐  │
│  │  App         │ ◄──redirect──► │  istio-proxy   │  │
│  │  Container   │                │  (Envoy)       │  │
│  │  :8080       │                │  :15001 out    │  │
│  │              │                │  :15006 in     │  │
│  │              │                │  :15020 status │  │
│  │              │                │  :15090 prom   │  │
│  └─────────────┘                └────────────────┘  │
│                                        │             │
│         init container:                │             │
│         istio-init (iptables setup)    │             │
└────────────────────────────────────────┼─────────────┘
                                         │
                                    xDS (gRPC)
                                         │
                                    ┌────▼────┐
                                    │ istiod   │
                                    │ (Pilot)  │
                                    └─────────┘
```

Key ports:
- **15001** — Outbound traffic capture (REDIRECT or TPROXY)
- **15006** — Inbound traffic capture
- **15020** — Merged Prometheus metrics and health
- **15021** — Health check endpoint
- **15090** — Envoy Prometheus stats

### Istio xDS: Pilot/istiod to Envoy

istiod translates Kubernetes services and Istio CRDs into Envoy xDS configuration:

| Istio CRD | Envoy xDS Resource | Purpose |
|------------|-------------------|---------|
| `VirtualService` | RDS (RouteConfiguration) | Routing rules, retries, timeouts |
| `DestinationRule` | CDS (Cluster) | LB policy, circuit breakers, TLS mode |
| `ServiceEntry` | CDS + EDS | External service registration |
| `Gateway` | LDS (Listener) | Ingress/egress gateway listeners |
| `Sidecar` | LDS (Listener) | Scope sidecar egress to specific services |
| `EnvoyFilter` | Any | Direct Envoy config patches |
| `PeerAuthentication` | Filter chain (TLS) | mTLS policy |
| `AuthorizationPolicy` | RBAC filter | L7 access control |
| `RequestAuthentication` | JWT authn filter | JWT validation |

### EnvoyFilter CRD — Patching Generated Config

EnvoyFilter allows injecting custom Envoy configuration into Istio-generated config:

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: add-lua-filter
  namespace: my-namespace
spec:
  workloadSelector:
    labels:
      app: my-app
  configPatches:
    # Add a Lua filter before the router
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
              subFilter:
                name: envoy.filters.http.router
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.lua
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
            default_source_code:
              inline_string: |
                function envoy_on_request(request_handle)
                  request_handle:headers():add("x-custom-header", "istio-lua")
                end

    # Modify cluster settings
    - applyTo: CLUSTER
      match:
        context: SIDECAR_OUTBOUND
        cluster:
          service: my-backend.my-namespace.svc.cluster.local
      patch:
        operation: MERGE
        value:
          connect_timeout: 5s
          circuit_breakers:
            thresholds:
              - max_connections: 2048
                max_pending_requests: 2048

    # Add custom listener filter
    - applyTo: LISTENER
      match:
        context: SIDECAR_INBOUND
      patch:
        operation: MERGE
        value:
          per_connection_buffer_limit_bytes: 2097152
```

**EnvoyFilter patch contexts:**
- `SIDECAR_INBOUND` — Traffic arriving at the pod.
- `SIDECAR_OUTBOUND` — Traffic leaving the pod.
- `GATEWAY` — Istio ingress/egress gateway.
- `ANY` — All contexts.

**applyTo targets:**
- `LISTENER`, `FILTER_CHAIN`, `NETWORK_FILTER`, `HTTP_FILTER`
- `ROUTE_CONFIGURATION`, `VIRTUAL_HOST`, `HTTP_ROUTE`
- `CLUSTER`, `EXTENSION_CONFIG`, `BOOTSTRAP`

### Istio Traffic Policies → Envoy Config Mapping

**VirtualService → Envoy routes:**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
    - reviews
  http:
    - match:
        - headers:
            end-user:
              exact: jason
      route:
        - destination:
            host: reviews
            subset: v2
    - route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10
      retries:
        attempts: 3
        perTryTimeout: 2s
      timeout: 10s
      fault:
        delay:
          percentage:
            value: 5
          fixedDelay: 3s
```

This generates Envoy RouteConfiguration with header matchers, weighted clusters, retry policies, timeouts, and fault injection — all the same patterns as native Envoy config.

**DestinationRule → Envoy cluster:**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100         # → circuit_breakers.max_connections
      http:
        h2UpgradePolicy: UPGRADE   # → http2_protocol_options
        maxRequestsPerConnection: 1000  # → common_http_protocol_options.max_requests_per_connection
    outlierDetection:
      consecutive5xxErrors: 5       # → outlier_detection.consecutive_5xx
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
    loadBalancer:
      simple: LEAST_REQUEST        # → lb_policy: LEAST_REQUEST
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

### Debugging Istio Sidecar

```bash
# Dump Envoy config from sidecar
istioctl proxy-config all <pod-name> -o json

# Specific resource types
istioctl proxy-config listeners <pod-name>
istioctl proxy-config routes <pod-name>
istioctl proxy-config clusters <pod-name>
istioctl proxy-config endpoints <pod-name>

# Check sync status with istiod
istioctl proxy-status

# Analyze for misconfigurations
istioctl analyze

# Direct admin access to sidecar Envoy
kubectl port-forward <pod-name> 15000:15000
curl localhost:15000/config_dump
curl localhost:15000/clusters
curl localhost:15000/stats?filter=upstream_rq

# Enable debug logging on sidecar
istioctl proxy-config log <pod-name> --level debug
# Or specific components:
istioctl proxy-config log <pod-name> --level connection:debug,upstream:debug

# Compare expected vs actual config
istioctl proxy-config routes <pod-name> -o json | \
  python3 -c "import json,sys; [print(r['name']) for r in json.load(sys.stdin)]"
```

---

## Consul Connect Dataplane

### Consul Envoy Integration

Consul Connect uses Envoy as its data plane proxy. consul-dataplane (or consul connect envoy) bootstraps Envoy with Consul's xDS server.

```
┌─────────────────────────────────┐
│         Kubernetes Pod          │
│                                 │
│  ┌──────────┐  ┌─────────────┐  │
│  │  App      │  │ consul-     │  │
│  │  :8080    │  │ dataplane   │  │
│  │           │  │ (Envoy)     │  │
│  └──────────┘  │ :20000 pub  │  │
│                │ :20001 admin│  │
│                └──────┬──────┘  │
│                       │         │
└───────────────────────┼─────────┘
                        │ xDS
                   ┌────▼────┐
                   │ Consul   │
                   │ Server   │
                   └─────────┘
```

Bootstrap generation:
```bash
# Generate and run Envoy with Consul bootstrap
consul connect envoy -sidecar-for my-service -admin-bind localhost:19000

# Or with consul-dataplane (newer approach)
consul-dataplane \
  -addresses="consul-server:8502" \
  -service-name="my-service" \
  -service-namespace="default" \
  -service-partition="default" \
  -login-auth-method="auth-method" \
  -envoy-admin-bind-address="localhost:19000"
```

### Consul Intentions → Envoy RBAC

Consul Intentions (service-to-service access control) map to Envoy RBAC filters:

```hcl
# Consul intention: Allow "web" to talk to "api"
Kind = "service-intentions"
Name = "api"
Sources = [
  {
    Name   = "web"
    Action = "allow"
  },
  {
    Name   = "*"
    Action = "deny"
  }
]
```

This generates Envoy RBAC network filter config that validates the SPIFFE identity in the client's mTLS certificate:
```yaml
# Generated Envoy config (simplified)
filters:
  - name: envoy.filters.network.rbac
    typed_config:
      rules:
        policies:
          "consul-intentions-layer4":
            permissions:
              - any: true
            principals:
              - authenticated:
                  principal_name:
                    exact: "spiffe://dc1/ns/default/dc/dc1/svc/web"
```

### Consul Service Defaults and Proxy Config

```hcl
# service-defaults.hcl
Kind = "service-defaults"
Name = "my-service"
Protocol = "http"

# Maps to Envoy cluster settings
UpstreamConfig {
  Defaults {
    ConnectTimeoutMs = 5000
    Limits {
      MaxConnections         = 512
      MaxPendingRequests      = 512
      MaxConcurrentRequests   = 512
    }
    PassiveHealthCheck {
      Interval     = "10s"
      MaxFailures  = 5
      EnforcingConsecutive5xx = 100
    }
  }
}

# Envoy-specific proxy configuration
EnvoyExtensions = [
  {
    Name = "builtin/lua"
    Arguments = {
      ProxyType = "connect-proxy"
      Listener  = "inbound"
      Script    = <<-EOF
        function envoy_on_request(handle)
          handle:headers():add("x-consul-processed", "true")
        end
      EOF
    }
  }
]
```

---

## AWS App Mesh

### App Mesh Architecture

AWS App Mesh provides a managed control plane that configures Envoy sidecars:

```
┌──────────────────────────────────────────┐
│            AWS App Mesh (Control Plane)   │
│              ├── Mesh                     │
│              ├── Virtual Nodes            │
│              ├── Virtual Services         │
│              ├── Virtual Routers          │
│              └── Virtual Gateways         │
└────────────────────┬─────────────────────┘
                     │ xDS
        ┌────────────┼────────────┐
   ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
   │ ECS Task │  │ ECS Task │  │ EKS Pod │
   │ ┌──────┐ │  │ ┌──────┐ │  │ ┌──────┐│
   │ │Envoy │ │  │ │Envoy │ │  │ │Envoy ││
   │ │Sidecar│ │  │ │Sidecar│ │  │ │Sidecar││
   │ └──────┘ │  │ └──────┘ │  │ └──────┘│
   │ ┌──────┐ │  │ ┌──────┐ │  │ ┌──────┐│
   │ │ App  │ │  │ │ App  │ │  │ │ App  ││
   │ └──────┘ │  │ └──────┘ │  │ └──────┘│
   └──────────┘  └──────────┘  └─────────┘
```

### Virtual Node and Virtual Service

```yaml
# AWS CloudFormation / CDK
# Virtual Node — represents a deployment/task group
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  MyVirtualNode:
    Type: AWS::AppMesh::VirtualNode
    Properties:
      MeshName: my-mesh
      VirtualNodeName: my-service
      Spec:
        Listeners:
          - PortMapping:
              Port: 8080
              Protocol: http
            HealthCheck:
              Protocol: http
              Path: /healthz
              HealthyThreshold: 2
              UnhealthyThreshold: 3
              TimeoutMillis: 2000
              IntervalMillis: 5000
            ConnectionPool:
              Http:
                MaxConnections: 1024
                MaxPendingRequests: 1024
        ServiceDiscovery:
          DNS:
            Hostname: my-service.my-namespace.svc.cluster.local
        Backends:
          - VirtualService:
              VirtualServiceName: backend-service
        BackendDefaults:
          ClientPolicy:
            TLS:
              Enforce: true
              Validation:
                Trust:
                  ACM:
                    CertificateAuthorityArns:
                      - arn:aws:acm-pca:us-east-1:123456789:certificate-authority/abc

  # Virtual Router with weighted targets
  MyVirtualRouter:
    Type: AWS::AppMesh::VirtualRouter
    Properties:
      MeshName: my-mesh
      VirtualRouterName: my-router
      Spec:
        Listeners:
          - PortMapping:
              Port: 8080
              Protocol: http

  MyRoute:
    Type: AWS::AppMesh::Route
    Properties:
      MeshName: my-mesh
      VirtualRouterName: my-router
      RouteName: my-route
      Spec:
        HttpRoute:
          Match:
            Prefix: /
          Action:
            WeightedTargets:
              - VirtualNode: my-service-v1
                Weight: 90
              - VirtualNode: my-service-v2
                Weight: 10
          RetryPolicy:
            MaxRetries: 3
            PerRetryTimeout:
              Value: 2
              Unit: s
            HttpRetryEvents:
              - server-error
              - gateway-error
```

### App Mesh Envoy Config

App Mesh uses a custom Envoy build. Configuration is delivered via xDS from the App Mesh control plane. The Envoy sidecar container is configured with:

```yaml
# ECS Task Definition (excerpt)
containerDefinitions:
  - name: envoy
    image: public.ecr.aws/appmesh/aws-appmesh-envoy:v1.27.0.0-prod
    essential: true
    environment:
      - name: APPMESH_RESOURCE_ARN
        value: "arn:aws:appmesh:us-east-1:123456789:mesh/my-mesh/virtualNode/my-service"
      - name: ENVOY_LOG_LEVEL
        value: "info"
      - name: ENABLE_ENVOY_XRAY_TRACING
        value: "1"
      - name: ENABLE_ENVOY_STATS_TAGS
        value: "1"
    healthCheck:
      command: ["CMD-SHELL", "curl -s http://localhost:9901/server_info | grep state | grep -q LIVE"]
      interval: 5
      timeout: 2
      retries: 3
```

---

## xDS Control Planes

### go-control-plane

The reference Go implementation for building xDS control planes:

```go
package main

import (
    "context"
    "log"
    "net"

    clusterv3 "github.com/envoyproxy/go-control-plane/envoy/config/cluster/v3"
    corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
    endpointv3 "github.com/envoyproxy/go-control-plane/envoy/config/endpoint/v3"
    listenerv3 "github.com/envoyproxy/go-control-plane/envoy/config/listener/v3"
    routev3 "github.com/envoyproxy/go-control-plane/envoy/config/route/v3"
    hcmv3 "github.com/envoyproxy/go-control-plane/envoy/extensions/filters/network/http_connection_manager/v3"
    routerv3 "github.com/envoyproxy/go-control-plane/envoy/extensions/filters/http/router/v3"
    discoveryv3 "github.com/envoyproxy/go-control-plane/envoy/service/discovery/v3"
    "github.com/envoyproxy/go-control-plane/pkg/cache/v3"
    "github.com/envoyproxy/go-control-plane/pkg/resource/v3"
    serverv3 "github.com/envoyproxy/go-control-plane/pkg/server/v3"
    "google.golang.org/grpc"
    "google.golang.org/protobuf/types/known/anypb"
    "google.golang.org/protobuf/types/known/durationpb"
)

func main() {
    // Create a snapshot cache (thread-safe, versioned config store)
    snapshotCache := cache.NewSnapshotCache(
        false,                    // ADS mode
        cache.IDHash{},           // Node hash function
        nil,                      // Logger
    )

    // Build resources
    cluster := makeCluster("my_service", "backend", 8080)
    listener := makeListener("http_listener", 8080, "my_service")

    // Create a config snapshot (version must change on updates)
    snapshot, _ := cache.NewSnapshot("v1",
        map[resource.Type][]cache.Resource{
            resource.ClusterType:  {cluster},
            resource.ListenerType: {listener},
        },
    )

    // Set snapshot for node "envoy-node-1"
    snapshotCache.SetSnapshot(context.Background(), "envoy-node-1", snapshot)

    // Start gRPC server
    server := serverv3.NewServer(context.Background(), snapshotCache, nil)
    grpcServer := grpc.NewServer()
    discoveryv3.RegisterAggregatedDiscoveryServiceServer(grpcServer, server)

    lis, _ := net.Listen("tcp", ":18000")
    log.Println("xDS server listening on :18000")
    grpcServer.Serve(lis)
}

func makeCluster(name, address string, port uint32) *clusterv3.Cluster {
    return &clusterv3.Cluster{
        Name:           name,
        ConnectTimeout: durationpb.New(5 * 1e9),
        ClusterDiscoveryType: &clusterv3.Cluster_Type{
            Type: clusterv3.Cluster_STRICT_DNS,
        },
        LoadAssignment: &endpointv3.ClusterLoadAssignment{
            ClusterName: name,
            Endpoints: []*endpointv3.LocalityLbEndpoints{{
                LbEndpoints: []*endpointv3.LbEndpoint{{
                    HostIdentifier: &endpointv3.LbEndpoint_Endpoint{
                        Endpoint: &endpointv3.Endpoint{
                            Address: &corev3.Address{
                                Address: &corev3.Address_SocketAddress{
                                    SocketAddress: &corev3.SocketAddress{
                                        Address: address,
                                        PortSpecifier: &corev3.SocketAddress_PortValue{
                                            PortValue: port,
                                        },
                                    },
                                },
                            },
                        },
                    },
                }},
            }},
        },
    }
}

func makeListener(name string, port uint32, clusterName string) *listenerv3.Listener {
    routerTypedConfig, _ := anypb.New(&routerv3.Router{})

    hcm := &hcmv3.HttpConnectionManager{
        StatPrefix: "ingress",
        RouteSpecifier: &hcmv3.HttpConnectionManager_RouteConfig{
            RouteConfig: &routev3.RouteConfiguration{
                VirtualHosts: []*routev3.VirtualHost{{
                    Name:    "local_service",
                    Domains: []string{"*"},
                    Routes: []*routev3.Route{{
                        Match: &routev3.RouteMatch{
                            PathSpecifier: &routev3.RouteMatch_Prefix{Prefix: "/"},
                        },
                        Action: &routev3.Route_Route{
                            Route: &routev3.RouteAction{
                                ClusterSpecifier: &routev3.RouteAction_Cluster{
                                    Cluster: clusterName,
                                },
                            },
                        },
                    }},
                }},
            },
        },
        HttpFilters: []*hcmv3.HttpFilter{{
            Name:       "envoy.filters.http.router",
            ConfigType: &hcmv3.HttpFilter_TypedConfig{TypedConfig: routerTypedConfig},
        }},
    }

    hcmTypedConfig, _ := anypb.New(hcm)

    return &listenerv3.Listener{
        Name: name,
        Address: &corev3.Address{
            Address: &corev3.Address_SocketAddress{
                SocketAddress: &corev3.SocketAddress{
                    Address: "0.0.0.0",
                    PortSpecifier: &corev3.SocketAddress_PortValue{
                        PortValue: port,
                    },
                },
            },
        },
        FilterChains: []*listenerv3.FilterChain{{
            Filters: []*listenerv3.Filter{{
                Name: "envoy.filters.network.http_connection_manager",
                ConfigType: &listenerv3.Filter_TypedConfig{
                    TypedConfig: hcmTypedConfig,
                },
            }},
        }},
    }
}
```

### java-control-plane

```java
// Java xDS control plane using envoy/java-control-plane
import io.envoyproxy.controlplane.cache.v3.SimpleCache;
import io.envoyproxy.controlplane.cache.v3.Snapshot;
import io.envoyproxy.controlplane.server.V3DiscoveryServer;
import io.grpc.Server;
import io.grpc.ServerBuilder;

public class XdsServer {
    public static void main(String[] args) throws Exception {
        // SimpleCache uses node group to key snapshots
        SimpleCache<String> cache = new SimpleCache<>(node -> "default-group");

        // Build snapshot
        Snapshot snapshot = Snapshot.create(
            List.of(makeCluster("my_service")),     // clusters
            List.of(makeEndpoint("my_service")),    // endpoints
            List.of(makeListener("http_listener")), // listeners
            List.of(makeRoute("local_route")),      // routes
            List.of(),                               // secrets
            "v1"                                     // version
        );

        cache.setSnapshot("default-group", snapshot);

        V3DiscoveryServer discoveryServer = new V3DiscoveryServer(cache);

        Server server = ServerBuilder.forPort(18000)
            .addService(discoveryServer.getAggregatedDiscoveryServiceImpl())
            .addService(discoveryServer.getClusterDiscoveryServiceImpl())
            .addService(discoveryServer.getListenerDiscoveryServiceImpl())
            .addService(discoveryServer.getRouteDiscoveryServiceImpl())
            .addService(discoveryServer.getEndpointDiscoveryServiceImpl())
            .build();

        server.start();
        System.out.println("xDS server listening on :18000");
        server.awaitTermination();
    }
}
```

### Building a Custom Control Plane

Design considerations for production xDS control planes:

**1. Node identification and grouping:**
```go
// Hash function determines which snapshot a node gets
type NodeHash struct{}

func (NodeHash) ID(node *corev3.Node) string {
    // Group by cluster + locality
    return fmt.Sprintf("%s/%s", node.Cluster, node.Locality.GetZone())
}
```

**2. Snapshot consistency:**
- Always update all dependent resources atomically.
- Version strings must change on every update.
- Use `cache.NewSnapshot()` which validates resource consistency.

**3. Resource ordering (ADS):**
- CDS/EDS before LDS/RDS to avoid referencing non-existent clusters.
- go-control-plane handles ordering automatically when using ADS.

**4. Health checking and warm-up:**
- New clusters should have endpoints before listeners reference them.
- Use `initial_fetch_timeout` to avoid blocking on missing resources.

**5. Delta xDS for scale:**
```go
// Use DeltaSnapshotCache for large deployments
deltaCache := cache.NewLinearCache(resource.ClusterType)
deltaCache.UpdateResource("cluster-1", makeCluster("cluster-1"))
// Only sends changed resources to subscribed Envoys
```

---

## Envoy Gateway

### Architecture Overview

Envoy Gateway is the official Envoy project for Kubernetes ingress/gateway using the Gateway API:

```
┌─────────────────────────────────────────────────────┐
│              Kubernetes Cluster                      │
│                                                     │
│  ┌──────────────┐     ┌─────────────────────────┐   │
│  │ Gateway API   │     │ Envoy Gateway            │   │
│  │ Resources:    │────►│ Controller               │   │
│  │ - GatewayClass│     │ (translates to xDS)      │   │
│  │ - Gateway     │     └───────────┬──────────────┘   │
│  │ - HTTPRoute   │                 │ xDS               │
│  │ - GRPCRoute   │                 │                   │
│  │ - TLSRoute    │     ┌───────────▼──────────────┐   │
│  └──────────────┘     │ Envoy Proxy Fleet         │   │
│                        │ (managed Envoy pods)      │   │
│                        │ ┌────┐ ┌────┐ ┌────┐     │   │
│                        │ │Envoy│ │Envoy│ │Envoy│    │   │
│                        │ └────┘ └────┘ └────┘     │   │
│                        └──────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

Install:
```bash
# Helm install
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.1.0 \
  -n envoy-gateway-system --create-namespace

# Or YAML
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.1.0/install.yaml
```

### Gateway API Resources

```yaml
# GatewayClass — defines which controller manages gateways
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller

---
# Gateway — creates Envoy proxy deployment and LoadBalancer service
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: my-tls-cert

---
# HTTPRoute — routing rules
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  hostnames:
    - "app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-service
          port: 8080
          weight: 90
        - name: api-service-canary
          port: 8080
          weight: 10
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            add:
              - name: X-Gateway
                value: envoy
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend-service
          port: 3000
```

### Envoy Gateway Configuration

Envoy Gateway-specific extensions (beyond Gateway API):

```yaml
# EnvoyProxy — customize the managed Envoy fleet
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 3
        container:
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 2000m
              memory: 1Gi
          env:
            - name: ENVOY_CONCURRENCY
              value: "2"
  telemetry:
    metrics:
      prometheus:
        disable: false
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              method: "%REQ(:METHOD)%"
              path: "%REQ(:PATH)%"
              status: "%RESPONSE_CODE%"
              duration: "%DURATION%"

---
# SecurityPolicy — auth and rate limiting
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: jwt-auth
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-app-route
  jwt:
    providers:
      - name: auth0
        issuer: https://my-tenant.auth0.com/
        audiences:
          - my-api
        remoteJWKS:
          uri: https://my-tenant.auth0.com/.well-known/jwks.json

---
# BackendTrafficPolicy — timeouts, retries, circuit breaking
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: retry-policy
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-app-route
  retry:
    numRetries: 3
    perRetry:
      timeout: 2s
    retryOn:
      httpStatusCodes:
        - 503
        - 502
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 1024
    maxParallelRequests: 1024
  timeout:
    http:
      requestTimeout: 30s
      connectionIdleTimeout: 300s
```

### Advanced Envoy Gateway Patterns

**Rate limiting:**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: rate-limit
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-app-route
  rateLimit:
    type: Global
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: x-api-key
                  type: Distinct
          limit:
            requests: 100
            unit: Minute
```

**CORS:**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: cors-policy
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: my-app-route
  cors:
    allowOrigins:
      - type: Exact
        value: "https://app.example.com"
    allowMethods:
      - GET
      - POST
      - PUT
    allowHeaders:
      - Authorization
      - Content-Type
    maxAge: 86400s
```

---

## Gateway API Support

### Gateway API Concepts

The Gateway API is a Kubernetes SIG-Network project providing role-oriented, expressive routing:

```
Infrastructure Provider          Cluster Operator          Application Developer
       │                              │                            │
       ▼                              ▼                            ▼
  GatewayClass ──────────────► Gateway ──────────────────► HTTPRoute
  (who provides)              (where/how to listen)       (what to route)
```

**Role separation:**
- **GatewayClass** — Infrastructure team defines available gateway implementations.
- **Gateway** — Platform team creates gateways with specific listeners.
- **HTTPRoute/GRPCRoute** — App teams define routing per their namespaces.

### HTTPRoute Configuration

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: complex-routing
spec:
  parentRefs:
    - name: my-gateway
      sectionName: https  # Attach to specific listener
  hostnames:
    - "api.example.com"
  rules:
    # Path + method matching with header modification
    - matches:
        - path:
            type: PathPrefix
            value: /v2/
          method: POST
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-API-Version
                value: "2"
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            remove:
              - Server
      backendRefs:
        - name: api-v2
          port: 8080

    # URL rewrite
    - matches:
        - path:
            type: PathPrefix
            value: /old-api/
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /api/
      backendRefs:
        - name: api-service
          port: 8080

    # Request redirect
    - matches:
        - path:
            type: Exact
            value: /legacy
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            hostname: new.example.com
            statusCode: 301

    # Mirror traffic
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: production
          port: 8080
      filters:
        - type: RequestMirror
          requestMirror:
            backendRef:
              name: shadow-service
              port: 8080
```

### GRPCRoute and TLSRoute

```yaml
# GRPCRoute — native gRPC routing
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: grpc-route
spec:
  parentRefs:
    - name: my-gateway
  hostnames:
    - "grpc.example.com"
  rules:
    - matches:
        - method:
            service: mypackage.MyService
            method: GetItem
      backendRefs:
        - name: grpc-service
          port: 50051

---
# TLSRoute — TLS passthrough
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: tls-passthrough
spec:
  parentRefs:
    - name: my-gateway
      sectionName: tls-passthrough
  hostnames:
    - "secure.example.com"
  rules:
    - backendRefs:
        - name: backend-with-own-tls
          port: 443
```

### BackendTLSPolicy

```yaml
# Configure TLS from gateway to backend
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: backend-tls
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: api-service
  validation:
    caCertificateRefs:
      - name: backend-ca-cert
        group: ""
        kind: ConfigMap
    hostname: api-service.internal
```
