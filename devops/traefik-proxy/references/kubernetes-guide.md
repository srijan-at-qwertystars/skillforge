# Traefik on Kubernetes Guide

## Table of Contents

- [Helm Chart Configuration](#helm-chart-configuration)
- [IngressRoute CRDs](#ingressroute-crds)
- [Middleware CRDs](#middleware-crds)
- [TLSOption CRD](#tlsoption-crd)
- [Cross-Namespace References](#cross-namespace-references)
- [Traefik as Ingress Controller vs IngressRoute](#traefik-as-ingress-controller-vs-ingressroute)
- [cert-manager Integration](#cert-manager-integration)

---

## Helm Chart Configuration

### Installation

```bash
# Add Traefik Helm repository
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Install with default values
helm install traefik traefik/traefik -n traefik --create-namespace

# Install with custom values
helm install traefik traefik/traefik -n traefik --create-namespace -f values.yml
```

### Key Helm Values

```yaml
# values.yml
image:
  tag: v3.4

deployment:
  replicas: 2
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8082"

ingressClass:
  enabled: true
  isDefaultClass: true    # Set as default IngressClass

ingressRoute:
  dashboard:
    enabled: true
    matchRule: Host(`traefik.example.com`)
    entryPoints: [websecure]
    middlewares:
      - name: dashboard-auth

ports:
  web:
    port: 8000
    exposedPort: 80
    redirectTo:
      port: websecure
  websecure:
    port: 8443
    exposedPort: 443
    http3:
      enabled: true
    tls:
      enabled: true
  metrics:
    port: 8082
    expose:
      default: false

service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: "1"
    memory: 512Mi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70

persistence:
  enabled: true
  size: 128Mi
  path: /data
  accessMode: ReadWriteOnce

additionalArguments:
  - "--providers.kubernetesingress.allowexternalnameservices=true"
  - "--providers.kubernetescrd.allowexternalnameservices=true"

logs:
  general:
    level: INFO
    format: json
  access:
    enabled: true
    format: json
    filters:
      statuscodes: "400-599"

metrics:
  prometheus:
    entryPoint: metrics
    addRoutersLabels: true
    addServicesLabels: true

providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true
    allowExternalNameServices: true
  kubernetesIngress:
    enabled: true
    allowExternalNameServices: true
    publishedService:
      enabled: true

tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
          topologyKey: kubernetes.io/hostname

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: traefik
```

### Upgrade

```bash
helm repo update
helm upgrade traefik traefik/traefik -n traefik -f values.yml

# CRDs are NOT updated by helm upgrade — apply manually
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.4/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
```

---

## IngressRoute CRDs

IngressRoute is Traefik's native CRD, offering more features than standard Kubernetes Ingress.

### Basic IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: webapp
  namespace: production
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: webapp-service
          port: 80
          weight: 100
      middlewares:
        - name: security-headers
        - name: rate-limit
  tls:
    certResolver: letsencrypt
    domains:
      - main: app.example.com
        sans:
          - "*.app.example.com"
```

### Multi-Path Routing

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: api-routes
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`api.example.com`) && PathPrefix(`/v1`)
      kind: Rule
      services:
        - name: api-v1
          port: 8080
      middlewares:
        - name: strip-v1-prefix

    - match: Host(`api.example.com`) && PathPrefix(`/v2`)
      kind: Rule
      services:
        - name: api-v2
          port: 8080
      middlewares:
        - name: strip-v2-prefix

    - match: Host(`api.example.com`) && PathPrefix(`/health`)
      kind: Rule
      services:
        - name: health-service
          port: 8081
  tls:
    certResolver: letsencrypt
```

### Weighted Round Robin (Canary)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: canary-split
spec:
  weighted:
    services:
      - name: app-stable
        port: 80
        weight: 90
      - name: app-canary
        port: 80
        weight: 10
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-canary-route
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: canary-split
          kind: TraefikService
  tls:
    certResolver: letsencrypt
```

### Traffic Mirroring

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: mirror-traffic
spec:
  mirroring:
    name: production-svc
    port: 80
    mirrors:
      - name: shadow-svc
        port: 80
        percent: 10
```

### TCP IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres-route
spec:
  entryPoints: [postgres]
  routes:
    - match: HostSNI(`db.example.com`)
      services:
        - name: postgres-service
          port: 5432
  tls:
    passthrough: true
```

### UDP IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteUDP
metadata:
  name: dns-route
spec:
  entryPoints: [dns-udp]
  routes:
    - services:
        - name: dns-service
          port: 53
```

---

## Middleware CRDs

Define middleware as Kubernetes resources and reference them in IngressRoutes.

### Headers Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    frameDeny: true
    contentTypeNosniff: true
    browserXssFilter: true
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
    customResponseHeaders:
      X-Powered-By: ""
      Server: ""
    referrerPolicy: strict-origin-when-cross-origin
    contentSecurityPolicy: "default-src 'self'"
```

### Rate Limit Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1s
    sourceCriterion:
      ipStrategy:
        depth: 1
```

### BasicAuth Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-auth
spec:
  basicAuth:
    secret: dashboard-credentials
    removeHeader: true
---
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-credentials
type: kubernetes.io/basic-auth
stringData:
  users: |
    admin:$apr1$xyz$hashedpassword
```

### ForwardAuth Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: auth-verify
spec:
  forwardAuth:
    address: http://authelia.auth.svc.cluster.local:9091/api/verify
    trustForwardHeader: true
    authResponseHeaders:
      - Remote-User
      - Remote-Groups
      - Remote-Email
```

### StripPrefix Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-prefix
spec:
  stripPrefix:
    prefixes:
      - /api/v1
```

### Chain Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: standard-chain
  namespace: traefik
spec:
  chain:
    middlewares:
      - name: security-headers
      - name: rate-limit
      - name: compress
```

### IPAllowList Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: internal-only
spec:
  ipAllowList:
    sourceRange:
      - 10.0.0.0/8
      - 172.16.0.0/12
    ipStrategy:
      depth: 1
```

### Compress Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: compress
spec:
  compress:
    excludedContentTypes:
      - text/event-stream
    minResponseBodyBytes: 1024
```

---

## TLSOption CRD

Control TLS versions and cipher suites per router.

### Modern TLS (1.3 only)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: modern
  namespace: traefik
spec:
  minVersion: VersionTLS13
```

### Intermediate TLS (1.2+)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: intermediate
  namespace: traefik
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
  curvePreferences:
    - X25519
    - CurveP256
    - CurveP384
  sniStrict: true
```

### Apply to IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: secure-app
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`secure.example.com`)
      kind: Rule
      services:
        - name: secure-service
          port: 443
  tls:
    options:
      name: modern
      namespace: traefik
```

### Default TLSOption

Name the TLSOption `default` in the Traefik namespace to apply it to all routes without explicit TLS options:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: default
  namespace: traefik
spec:
  minVersion: VersionTLS12
  sniStrict: true
```

### TLSStore (Default Certificate)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik
spec:
  defaultCertificate:
    secretName: default-tls-cert
```

---

## Cross-Namespace References

By default, Traefik CRDs can only reference resources in the same namespace.

### Enabling Cross-Namespace

In Helm values:
```yaml
providers:
  kubernetesCRD:
    allowCrossNamespace: true
```

Or as a CLI argument:
```yaml
additionalArguments:
  - "--providers.kubernetescrd.allowcrossnamespace=true"
```

### Referencing Middleware from Another Namespace

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-route
  namespace: production
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: app-service
          port: 80
      middlewares:
        - name: security-headers
          namespace: traefik        # Reference middleware in traefik namespace
        - name: rate-limit
          namespace: traefik
  tls:
    options:
      name: modern
      namespace: traefik            # Reference TLSOption in traefik namespace
```

### Pattern: Shared Middleware Namespace

Store all shared middleware in the `traefik` namespace:

```
traefik/                          # Namespace
├── Middleware/security-headers   # Shared across all apps
├── Middleware/rate-limit
├── Middleware/standard-chain
├── TLSOption/modern
└── TLSOption/intermediate

production/                       # Namespace
├── IngressRoute/app              # References traefik/security-headers
└── Service/app-service

staging/                          # Namespace
├── IngressRoute/app              # References same traefik/security-headers
└── Service/app-service
```

### Security Considerations

- Cross-namespace references bypass namespace isolation. A team in namespace A can reference (but not modify) middleware in namespace B.
- Use RBAC to control who can create IngressRoutes in each namespace.
- Consider using `allowCrossNamespace: false` (default) in multi-tenant clusters where teams should not share resources.

---

## Traefik as Ingress Controller vs IngressRoute

### Standard Kubernetes Ingress

Traefik can serve as a standard Ingress controller:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
  tls:
    - hosts: [app.example.com]
      secretName: app-tls
```

### Comparison

| Feature | Kubernetes Ingress | IngressRoute CRD |
|---|---|---|
| Portability | Standard, works with any controller | Traefik-specific |
| TCP/UDP routing | ❌ Not supported | ✅ IngressRouteTCP/UDP |
| Middleware | Via annotations (limited) | ✅ Native, typed CRDs |
| Weighted routing | ❌ | ✅ TraefikService |
| Traffic mirroring | ❌ | ✅ TraefikService |
| TLS options | Basic (secret ref) | ✅ TLSOption CRD |
| Match expressions | Path + Host only | Full rule syntax |
| Cross-namespace | Via IngressClass | ✅ allowCrossNamespace |
| Validation | Minimal | CRD schema validation |

### Kubernetes Gateway API

Traefik v3 supports Gateway API as a production-ready alternative:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - app.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-service
          port: 8080
          weight: 90
        - name: api-canary
          port: 8080
          weight: 10
```

Gateway API advantages:
- Standard API with broad vendor support.
- Role-oriented: platform team manages Gateway, app team manages HTTPRoute.
- Native weighted routing and header matching.
- Growing middleware support via policy attachment.

### Recommendation

- **New projects:** Consider Gateway API for future-proofing.
- **Traefik-specific features needed:** Use IngressRoute CRDs.
- **Multi-controller portability required:** Use standard Ingress.
- **Migrating from v2:** IngressRoute with updated API group (`traefik.io/v1alpha1`).

---

## cert-manager Integration

Use cert-manager instead of Traefik's built-in ACME for more control over certificate lifecycle.

### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true
```

### ClusterIssuer (Let's Encrypt)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-token
              key: api-token
        selector:
          dnsZones: ["example.com"]
```

### Certificate Resource

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-cert
  namespace: production
spec:
  secretName: app-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - app.example.com
    - "*.app.example.com"
  duration: 2160h      # 90 days
  renewBefore: 720h    # Renew 30 days before expiry
```

### Using with IngressRoute

Reference the cert-manager generated Secret in the IngressRoute:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-route
  namespace: production
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: app-service
          port: 80
  tls:
    secretName: app-tls    # Created by cert-manager Certificate
    # Do NOT set certResolver when using cert-manager
```

### Using with Standard Ingress + Annotations

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
    - hosts: [app.example.com]
      secretName: app-tls      # cert-manager creates this
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
```

### Traefik ACME vs cert-manager

| Feature | Traefik ACME | cert-manager |
|---|---|---|
| Setup complexity | Minimal | Separate install |
| Certificate storage | acme.json / KV store | Kubernetes Secrets |
| HA/multi-replica | Needs KV store | Native with Secrets |
| Custom CAs | Limited | ✅ Full support |
| Vault integration | ❌ | ✅ Vault issuer |
| Certificate policies | Basic | ✅ Rich policies |
| Monitoring | Metrics only | Events + conditions |
| Wildcard DNS | ✅ DNS challenge | ✅ DNS challenge |

**Recommendation:** Use cert-manager in production Kubernetes clusters for better HA, observability, and certificate management flexibility. Use Traefik's built-in ACME for simpler setups or Docker deployments.
