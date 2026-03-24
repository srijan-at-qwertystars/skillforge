---
name: istio-service-mesh
description: >
  Guide for configuring and operating Istio service mesh on Kubernetes.
  Covers traffic management (VirtualService, DestinationRule, Gateway, ServiceEntry),
  security (mTLS, PeerAuthentication, AuthorizationPolicy, RequestAuthentication),
  observability, resilience patterns (circuit breaking, retries, timeouts, fault injection),
  sidecar injection, ambient mesh mode, canary deployments, egress control,
  multi-cluster mesh, and Wasm plugin extensibility. Use for any Istio or Envoy-proxy
  service mesh task. Do NOT use for Linkerd, Consul Connect, or plain Kubernetes
  networking without Istio context.
triggers:
  positive:
    - Istio
    - service mesh
    - Envoy proxy
    - VirtualService
    - DestinationRule
    - mTLS
    - traffic management
    - sidecar injection
    - PeerAuthentication
    - AuthorizationPolicy
    - Gateway API Istio
    - istioctl
    - ambient mesh
    - waypoint proxy
  negative:
    - Linkerd
    - Consul Connect
    - general Kubernetes networking without Istio
    - plain Envoy without Istio
    - AWS App Mesh
    - Traefik mesh
---

# Istio Service Mesh Skill

## Architecture

Istio splits into a **data plane** (Envoy sidecar proxies) and a **control plane** (istiod).

- **istiod**: unified binary combining Pilot (config/discovery), Citadel (certificate management), and Galley (validation). Distributes config to Envoy via xDS APIs. Issues and rotates mTLS certificates automatically.
- **Envoy sidecar**: deployed per-pod, intercepts all inbound/outbound traffic. Handles routing, load balancing, TLS termination, retries, circuit breaking, telemetry collection. Extended via Wasm.
- **Ingress/Egress Gateway**: standalone Envoy deployments at mesh edge for north-south traffic.

## Installation

### istioctl (recommended for most teams)
```bash
# Install default profile
istioctl install --set profile=default -y
# Production profile with higher resource limits
istioctl install --set profile=production -y
# Verify installation
istioctl verify-install
# Pre-flight config analysis
istioctl analyze --all-namespaces
```

### Helm (recommended for GitOps / ArgoCD / Flux)
```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
# Install in order: base → istiod → gateway
helm install istio-base istio/base -n istio-system --create-namespace
helm install istiod istio/istiod -n istio-system --wait
helm install istio-ingress istio/gateway -n istio-ingress --create-namespace
```

### Profiles
Use `default` for dev, `demo` for learning (enables all addons), `minimal` for control-plane-only, `production` for hardened deployments. List with `istioctl profile list`. Diff with `istioctl profile diff default production`.

## Sidecar Injection

### Automatic (preferred)
```bash
kubectl label namespace <ns> istio-injection=enabled
# For revision-based (canary control plane upgrades):
kubectl label namespace <ns> istio.io/rev=<revision>
```

### Manual
```bash
istioctl kube-inject -f deployment.yaml | kubectl apply -f -
```

### Exclude pods from injection
```yaml
metadata:
  annotations:
    sidecar.istio.io/inject: "false"
```

## Traffic Management

### VirtualService — route traffic, split, match, rewrite
```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-route
spec:
  hosts: [reviews]
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
```

### DestinationRule — subsets, load balancing, connection pools
```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-dr
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST
  subsets:
    - name: v1
      labels: { version: v1 }
    - name: v2
      labels: { version: v2 }
```

### Gateway — ingress entry point
```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: app-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      tls:
        mode: SIMPLE
        credentialName: app-tls-cert
      hosts: ["app.example.com"]
```

### ServiceEntry — register external services
```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-api
spec:
  hosts: ["api.external.com"]
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: https
      protocol: TLS
  resolution: DNS
```

### Key rules
- Always define default routes even for single-version services.
- Use `exportTo: ["."]` to scope resources to their namespace.
- Bind VirtualService to specific gateways via `gateways:` field.
- Use `mesh` gateway for east-west (service-to-service) traffic.

## Resilience Patterns

### Timeouts
```yaml
http:
  - route:
      - destination: { host: myservice }
    timeout: 5s
```

### Retries
```yaml
http:
  - route:
      - destination: { host: myservice }
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,refused-stream
```

### Circuit Breaking (DestinationRule)
```yaml
trafficPolicy:
  connectionPool:
    tcp: { maxConnections: 100 }
    http:
      http1MaxPendingRequests: 100
      http2MaxRequests: 1000
      maxRequestsPerConnection: 10
  outlierDetection:
    consecutive5xxErrors: 5
    interval: 30s
    baseEjectionTime: 30s
    maxEjectionPercent: 50
```

### Fault Injection (testing only)
```yaml
http:
  - fault:
      delay:
        percentage: { value: 10 }
        fixedDelay: 5s
      abort:
        percentage: { value: 5 }
        httpStatus: 503
    route:
      - destination: { host: myservice }
```

## Security

### Strict mTLS mesh-wide
```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```
Start with `PERMISSIVE` during migration; monitor `connection_security_policy` label in metrics to find plaintext traffic, then switch to `STRICT`.

### AuthorizationPolicy — deny-by-default, then allow
```yaml
# Deny all in namespace
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: production
spec: {}
---
# Allow specific access
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend
  namespace: production
spec:
  selector:
    matchLabels: { app: backend }
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/frontend"]
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/*"]
```
Assign unique ServiceAccounts per workload. Never use the default SA for sensitive workloads.

### RequestAuthentication — JWT validation
```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
spec:
  selector:
    matchLabels: { app: api-gateway }
  jwtRules:
    - issuer: "https://auth.example.com"
      jwksUri: "https://auth.example.com/.well-known/jwks.json"
      forwardOriginalToken: true
```
Pair with AuthorizationPolicy to enforce claims-based access.

## Canary Deployments & Traffic Splitting

```yaml
# Shift 10% to canary
http:
  - route:
      - destination: { host: myapp, subset: stable }
        weight: 90
      - destination: { host: myapp, subset: canary }
        weight: 10
```
Progressively adjust weights (10→25→50→100). Use header-based routing for internal testing before weighted rollout. Integrate with Flagger or Argo Rollouts for automated canary analysis.

## Observability

- **Metrics**: Envoy emits request count, duration, size. Scrape with Prometheus. Key metrics: `istio_requests_total`, `istio_request_duration_milliseconds`.
- **Distributed tracing**: Propagate headers (`x-request-id`, `x-b3-traceid`, etc.). Integrate with Jaeger, Zipkin, or OpenTelemetry Collector. Configure sampling rate via `meshConfig.defaultConfig.tracing.sampling`.
- **Access logs**: Enable with `meshConfig.accessLogFile: /dev/stdout`. Use `meshConfig.accessLogEncoding: JSON` for structured logs.
- **Kiali**: Service mesh dashboard. Install via `kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml`. Visualize traffic graph, config validation, health status.
- **Grafana dashboards**: Install Istio dashboards for workload, service, and control plane metrics.

## Ambient Mesh (Sidecar-less Mode)

Ambient mesh removes per-pod sidecars. Uses two components:
- **ztunnel**: Rust-based DaemonSet, handles L4 (mTLS, TCP auth, telemetry). Minimal resource overhead.
- **waypoint proxy**: optional per-namespace Envoy for L7 features (HTTP routing, authorization, telemetry).

### Enable ambient mode
```bash
istioctl install --set profile=ambient
kubectl label namespace <ns> istio.io/dataplane-mode=ambient
```

### Deploy waypoint for L7
```bash
istioctl waypoint apply -n <ns> --enroll-namespace
```

Use ambient when: L4 security suffices for most services, resource efficiency is critical, or sidecar lifecycle complexity is prohibitive. Mix sidecar and ambient in the same mesh during migration.

## Egress Traffic Control

### Default: allow all outbound (meshConfig.outboundTrafficPolicy.mode: ALLOW_ANY)
### Restrict: set mode to REGISTRY_ONLY, then register external services via ServiceEntry.

```yaml
# Lock down egress
meshConfig:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
```
Combine ServiceEntry + egress Gateway for auditable, policy-controlled external access. Apply mTLS origination at the egress gateway for external TLS services.

## Multi-Cluster Mesh

- **Primary-Remote**: one cluster runs istiod, remote clusters connect to it.
- **Multi-Primary**: each cluster runs istiod, shares service discovery.
- Requirements: shared root CA, cross-cluster network connectivity (east-west gateway or flat network), shared trust domain.
- Use `istioctl create-remote-secret` to establish cluster identity.
- Configure `meshConfig.meshNetworks` for multi-network topologies.

## Wasm Plugins

Extend Envoy without recompiling. Use `WasmPlugin` CRD:
```yaml
apiVersion: extensions.istio.io/v1alpha1
kind: WasmPlugin
metadata:
  name: custom-auth
spec:
  selector:
    matchLabels: { app: myservice }
  url: oci://registry.example.com/wasm/custom-auth:v1
  phase: AUTHN
```
Phases: `AUTHN`, `AUTHZ`, `STATS`. Prefer `WasmPlugin` over `EnvoyFilter` for maintainability. Build plugins with proxy-wasm SDK (Rust, Go, C++, AssemblyScript).

## Troubleshooting

```bash
# Check proxy sync status
istioctl proxy-status
# Inspect Envoy config for a pod
istioctl proxy-config routes <pod> -n <ns>
istioctl proxy-config clusters <pod> -n <ns>
istioctl proxy-config listeners <pod> -n <ns>
# Analyze config issues
istioctl analyze -n <ns>
# Check sidecar injection
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].name}'
# Debug mTLS
istioctl authn tls-check <pod>.<ns>
# Envoy admin interface (port-forward)
kubectl port-forward <pod> 15000:15000
# Access at localhost:15000 for config_dump, stats, clusters
```

## Critical Best Practices

1. Pin Istio version in CI/CD; test upgrades in staging with revision-based canary.
2. Set resource requests/limits on sidecar proxies via `sidecar.istio.io/proxy*` annotations.
3. Use `Sidecar` CRD to limit Envoy config scope — reduces memory and xDS push time.
4. Enable `STRICT` mTLS mesh-wide; use `PERMISSIVE` only during migration.
5. Deploy deny-all AuthorizationPolicy per namespace, then layer ALLOW rules.
6. Set explicit timeouts on every VirtualService route.
7. Configure outlierDetection on every DestinationRule for automatic unhealthy endpoint ejection.
8. Propagate trace context headers in application code — Istio cannot do this automatically.
9. Run `istioctl analyze` in CI to catch misconfigurations before deploy.
10. Use `PeerAuthentication` port-level overrides for health check ports that must accept plaintext.

## References

In-depth guides in `references/`:

| File | Topics |
|------|--------|
| [traffic-management-guide.md](references/traffic-management-guide.md) | VirtualService matching, DestinationRule subsets, traffic splitting, header routing, fault injection, circuit breaking, retries, timeouts, mirroring, ServiceEntry, Sidecar scoping |
| [security-guide.md](references/security-guide.md) | PeerAuthentication modes, AuthorizationPolicy (ALLOW/DENY/CUSTOM), RequestAuthentication with JWT, ext-authz, certificate management, SPIFFE identity, cert-manager integration |
| [troubleshooting.md](references/troubleshooting.md) | Sidecar injection failures, 503 errors, mTLS issues, routing problems, Envoy config debugging, performance tuning, proxy-status/proxy-config, response flag codes, Kiali |

## Scripts

Operational scripts in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| [install-istio.sh](scripts/install-istio.sh) | Install Istio on a cluster — downloads istioctl, installs with profile, enables injection, optionally deploys sample app | `./scripts/install-istio.sh [profile] [namespace]` |
| [istio-debug.sh](scripts/istio-debug.sh) | Debug Istio issues — proxy-status, proxy-config, mTLS check, analyze, Envoy logs, certs, metrics | `./scripts/istio-debug.sh <command> [pod] [namespace]` |
| [canary-deploy.sh](scripts/canary-deploy.sh) | Canary deployment with progressive traffic shifting, health checks, and automatic rollback | `./scripts/canary-deploy.sh <service> <ns> <stable> <canary> [--auto]` |

## Assets

Ready-to-use Kubernetes manifests in `assets/`:

| File | Description |
|------|-------------|
| [istio-gateway.yaml](assets/istio-gateway.yaml) | Production Gateway + VirtualService for HTTPS ingress with HTTP redirect, CORS, timeouts |
| [canary-virtualservice.yaml](assets/canary-virtualservice.yaml) | Canary VirtualService with header-based testing and weighted traffic split |
| [authorization-policy.yaml](assets/authorization-policy.yaml) | Deny-by-default AuthorizationPolicy with per-service ALLOW rules and monitoring access |
| [peer-authentication.yaml](assets/peer-authentication.yaml) | Mesh-wide STRICT mTLS with port-level exceptions for health checks |
| [istio-operator-values.yaml](assets/istio-operator-values.yaml) | IstioOperator config with production resource limits, HPA, egress lockdown, CNI, ext-authz |
