# Traefik Kubernetes Integration Guide

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
  - [Helm Chart Installation](#helm-chart-installation)
  - [CRD Installation](#crd-installation)
  - [Helm Chart Values Reference](#helm-chart-values-reference)
- [CRD Reference](#crd-reference)
  - [IngressRoute (HTTP)](#ingressroute-http)
  - [IngressRouteTCP](#ingressroutetcp)
  - [IngressRouteUDP](#ingressrouteudp)
  - [Middleware CRD](#middleware-crd)
  - [TLSOption](#tlsoption)
  - [TLSStore](#tlsstore)
  - [TraefikService](#traefikservice)
  - [ServersTransport](#serverstransport)
  - [ServersTransportTCP](#serverstransporttcp)
- [Traffic Splitting and Canary](#traffic-splitting-and-canary)
- [cert-manager Integration](#cert-manager-integration)
- [RBAC Configuration](#rbac-configuration)
- [Cross-Namespace References](#cross-namespace-references)
- [High Availability](#high-availability)
- [Monitoring in Kubernetes](#monitoring-in-kubernetes)
- [Common Patterns](#common-patterns)
- [Migration from Ingress to IngressRoute](#migration-from-ingress-to-ingressroute)

---

## Overview

Traefik integrates with Kubernetes via Custom Resource Definitions (CRDs) that provide
richer functionality than standard Ingress resources. The `kubernetesCRD` provider watches
CRDs; the `kubernetesIngress` provider handles standard Ingress resources.

**CRD advantages over Ingress:**
- TCP/UDP routing support
- Middleware as CRDs (reusable across routes)
- Weighted traffic splitting (TraefikService)
- TLS options per route
- Cross-namespace references

---

## Installation

### Helm Chart Installation

```bash
# Add the Traefik Helm repository
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Install with default values
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace

# Install with custom values
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  -f values.yaml

# Upgrade existing installation
helm upgrade traefik traefik/traefik \
  --namespace traefik \
  -f values.yaml
```

### CRD Installation

CRDs are installed automatically by the Helm chart. For manual installation:

```bash
# Install CRDs separately (before Helm install with --skip-crds)
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.2/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# Verify CRDs
kubectl get crds | grep traefik
# Expected output:
# ingressroutes.traefik.io
# ingressroutetcps.traefik.io
# ingressrouteudps.traefik.io
# middlewares.traefik.io
# middlewaretcps.traefik.io
# serverstransports.traefik.io
# serverstransporttcps.traefik.io
# tlsoptions.traefik.io
# tlsstores.traefik.io
# traefikservices.traefik.io
```

### Helm Chart Values Reference

```yaml
# values.yaml — Production-ready configuration
image:
  repository: traefik
  tag: "v3.2"
  pullPolicy: IfNotPresent

deployment:
  replicas: 3
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8082"
  podLabels:
    app: traefik
  # Pod disruption budget
  minReadySeconds: 10
  # Anti-affinity for HA
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: [traefik]
          topologyKey: kubernetes.io/hostname

# Resource limits
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

# Entrypoints
ports:
  web:
    port: 8000
    exposedPort: 80
    protocol: TCP
    redirectTo:
      port: websecure
  websecure:
    port: 8443
    exposedPort: 443
    protocol: TCP
    tls:
      enabled: true
  metrics:
    port: 8082
    exposedPort: 8082
    protocol: TCP

# Service type
service:
  type: LoadBalancer
  annotations:
    # AWS NLB
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    # Or GCP
    # cloud.google.com/l4-rbs: "enabled"
  spec:
    externalTrafficPolicy: Local    # Preserve client IPs

# Providers
providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: true
    allowExternalNameServices: true
    namespaces: []    # Empty = all namespaces
  kubernetesIngress:
    enabled: true
    publishedService:
      enabled: true

# IngressClass
ingressClass:
  name: traefik
  isDefaultClass: true

# Dashboard
ingressRoute:
  dashboard:
    enabled: false    # We'll create our own secured route

# Let's Encrypt
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /data/acme.json
      httpChallenge:
        entryPoint: web
  letsencrypt-dns:
    acme:
      email: admin@example.com
      storage: /data/acme-dns.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "8.8.8.8:53"

# Persistence for ACME certificates
persistence:
  enabled: true
  name: data
  accessMode: ReadWriteOnce
  size: 128Mi
  storageClass: ""    # Use default StorageClass
  path: /data

# Logs
logs:
  general:
    level: INFO
    format: json
  access:
    enabled: true
    format: json
    fields:
      headers:
        defaultMode: drop
        names:
          User-Agent: keep
          X-Forwarded-For: keep

# Metrics
metrics:
  prometheus:
    entryPoint: metrics
    addRoutersLabels: true
    addServicesLabels: true

# Tracing
tracing:
  otlp:
    grpc:
      endpoint: "otel-collector.monitoring:4317"
      insecure: true

# Security context
securityContext:
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsGroup: 65532
  runAsNonRoot: true
  runAsUser: 65532

# Pod security context
podSecurityContext:
  fsGroup: 65532
  fsGroupChangePolicy: "OnRootMismatch"

# Additional volumes (for custom certs, etc.)
volumes:
  - name: custom-certs
    secret:
      secretName: custom-tls-certs

additionalVolumeMounts:
  - name: custom-certs
    mountPath: /certs
    readOnly: true

# Environment variables
env:
  - name: CF_DNS_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-credentials
        key: api-token

# Autoscaling
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

# Node selection
nodeSelector:
  kubernetes.io/os: linux

tolerations:
  - key: "node-role.kubernetes.io/infra"
    operator: "Exists"
    effect: "NoSchedule"

# Priority class
priorityClassName: system-cluster-critical

# Topology spread constraints
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: traefik
```

---

## CRD Reference

### IngressRoute (HTTP)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: webapp
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`webapp.example.com`)
      kind: Rule
      priority: 10
      middlewares:
        - name: security-headers
          namespace: traefik          # Cross-namespace reference
        - name: rate-limit
        - name: compress
      services:
        - name: webapp-svc
          port: 80
          weight: 100
          passHostHeader: true
          responseForwarding:
            flushInterval: 100ms
          strategy: RoundRobin
          # Health check
          healthCheck:
            path: /health
            interval: 10s
            timeout: 3s
    - match: Host(`webapp.example.com`) && PathPrefix(`/api`)
      kind: Rule
      priority: 20              # Higher priority for more specific route
      middlewares:
        - name: api-auth
        - name: strip-api-prefix
      services:
        - name: api-svc
          port: 8080
  tls:
    certResolver: letsencrypt
    domains:
      - main: webapp.example.com
        sans:
          - www.webapp.example.com
    options:
      name: modern-tls
      namespace: traefik
```

### IngressRouteTCP

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres
  namespace: databases
spec:
  entryPoints:
    - postgres        # Must be defined in Traefik static config
  routes:
    - match: HostSNI(`db.example.com`)
      services:
        - name: postgres-svc
          port: 5432
          weight: 100
          proxyProtocol:
            version: 2
  tls:
    passthrough: true   # TLS handled by backend
    # OR terminate TLS at Traefik:
    # certResolver: letsencrypt
    # options:
    #   name: mtls-strict
    #   namespace: traefik
---
# Entrypoint must be in Helm values:
# ports:
#   postgres:
#     port: 5432
#     exposedPort: 5432
#     protocol: TCP
```

### IngressRouteUDP

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteUDP
metadata:
  name: dns
  namespace: dns-system
spec:
  entryPoints:
    - dns             # Must be defined: address ":53/udp"
  routes:
    - services:
        - name: coredns-svc
          port: 53
          weight: 100
---
# Entrypoint in Helm values:
# ports:
#   dns:
#     port: 5353
#     exposedPort: 53
#     protocol: UDP
```

### Middleware CRD

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    sslRedirect: true
    forceSTSHeader: true
    stsSeconds: 63072000
    stsIncludeSubdomains: true
    stsPreload: true
    contentTypeNosniff: true
    browserXssFilter: true
    referrerPolicy: strict-origin-when-cross-origin
    frameDeny: true
    permissionsPolicy: "camera=(), microphone=(), geolocation=()"
    customResponseHeaders:
      X-Robots-Tag: "noindex, nofollow"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: traefik
spec:
  rateLimit:
    average: 100
    burst: 200
    period: 1s
    sourceCriterion:
      ipStrategy:
        depth: 1
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
  namespace: traefik
spec:
  basicAuth:
    secret: auth-secret    # htpasswd format in k8s Secret
    removeHeader: true
---
# Secret for basicAuth
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: traefik
type: kubernetes.io/basic-auth
stringData:
  users: |
    admin:$apr1$xyz$hashedpassword
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forward-auth
  namespace: traefik
spec:
  forwardAuth:
    address: http://oauth2-proxy.auth.svc.cluster.local:4180/oauth2/auth
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
      - X-Auth-Request-Groups
    authRequestHeaders:
      - Authorization
      - Cookie
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: compress
  namespace: traefik
spec:
  compress:
    excludedContentTypes:
      - text/event-stream
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: circuit-breaker
  namespace: traefik
spec:
  circuitBreaker:
    expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.25"
    checkPeriod: 10s
    fallbackDuration: 30s
    recoveryDuration: 60s
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: retry
  namespace: traefik
spec:
  retry:
    attempts: 3
    initialInterval: 500ms
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-prefix
  namespace: traefik
spec:
  stripPrefix:
    prefixes:
      - /api
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ip-allowlist
  namespace: traefik
spec:
  ipAllowList:
    sourceRange:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
---
# Middleware chain — compose multiple middlewares
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: production-stack
  namespace: traefik
spec:
  chain:
    middlewares:
      - name: security-headers
      - name: rate-limit
      - name: compress
      - name: retry
```

### TLSOption

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: modern-tls
  namespace: traefik
spec:
  minVersion: VersionTLS13
  sniStrict: true
---
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: intermediate-tls
  namespace: traefik
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
    - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  curvePreferences:
    - CurveP521
    - CurveP384
  sniStrict: true
---
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: mtls-strict
  namespace: traefik
spec:
  minVersion: VersionTLS12
  clientAuth:
    secretNames:
      - client-ca-cert       # k8s Secret containing CA cert
    clientAuthType: RequireAndVerifyClientCert
  sniStrict: true
---
# CA cert secret for mTLS
apiVersion: v1
kind: Secret
metadata:
  name: client-ca-cert
  namespace: traefik
type: Opaque
data:
  ca.crt: <base64-encoded-CA-cert>
```

### TLSStore

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default           # "default" is special — applies globally
  namespace: traefik
spec:
  defaultCertificate:
    secretName: default-tls-cert
  # Use for default cert when no SNI matches
---
# Default TLS certificate
apiVersion: v1
kind: Secret
metadata:
  name: default-tls-cert
  namespace: traefik
type: kubernetes.io/tls
data:
  tls.crt: <base64-cert>
  tls.key: <base64-key>
```

### TraefikService

TraefikService enables weighted round-robin (canary) and mirroring.

```yaml
# Weighted — Canary deployment
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: app-canary
  namespace: default
spec:
  weighted:
    services:
      - name: app-v1-svc
        port: 80
        weight: 90
      - name: app-v2-svc
        port: 80
        weight: 10
    sticky:
      cookie:
        name: canary_session
        secure: true
        httpOnly: true
        sameSite: strict
---
# Mirroring — Shadow traffic
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: app-mirrored
  namespace: default
spec:
  mirroring:
    name: app-primary-svc
    port: 80
    maxBodySize: 1048576
    mirrors:
      - name: app-shadow-svc
        port: 80
        percent: 5
---
# Use TraefikService in IngressRoute
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-canary-route
  namespace: default
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: app-canary        # References TraefikService
          kind: TraefikService
  tls:
    certResolver: letsencrypt
```

### ServersTransport

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: internal-transport
  namespace: default
spec:
  serverName: "internal.example.com"
  insecureSkipVerify: false
  rootCAsSecrets:
    - internal-ca
  certificatesSecrets:
    - client-cert
  maxIdleConnsPerHost: 100
  forwardingTimeouts:
    dialTimeout: 30s
    responseHeaderTimeout: 30s
    idleConnTimeout: 90s
  peerCertURI: "spiffe://cluster.local/ns/default/sa/myapp"
```

### ServersTransportTCP

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransportTCP
metadata:
  name: tcp-transport
  namespace: default
spec:
  dialTimeout: 30s
  dialKeepAlive: 30s
  tls:
    serverName: "db.internal"
    insecureSkipVerify: false
    rootCAsSecrets:
      - internal-ca
    certificatesSecrets:
      - client-cert
    peerCertURI: "spiffe://cluster.local/ns/default/sa/postgres"
```

---

## Traffic Splitting and Canary

### Progressive Canary Deployment

```yaml
# Step 1: 95/5 split
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: app-weighted
spec:
  weighted:
    services:
      - name: app-v1
        port: 80
        weight: 95
      - name: app-v2
        port: 80
        weight: 5
---
# Step 2: Monitor metrics, then update to 80/20
# kubectl edit traefikservice app-weighted
# Change weights to 80/20
---
# Step 3: Full rollout — 0/100
# Change weights to 0/100, then remove v1
```

### Header-Based Canary (Internal Testing)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-canary-internal
spec:
  entryPoints: [websecure]
  routes:
    # Canary route — higher priority, matches header
    - match: Host(`app.example.com`) && Headers(`X-Canary`, `true`)
      kind: Rule
      priority: 100
      services:
        - name: app-v2
          port: 80
    # Stable route — default
    - match: Host(`app.example.com`)
      kind: Rule
      priority: 50
      services:
        - name: app-v1
          port: 80
  tls:
    certResolver: letsencrypt
```

### A/B Testing with Cookie

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: ab-test
spec:
  weighted:
    services:
      - name: variant-a
        port: 80
        weight: 50
      - name: variant-b
        port: 80
        weight: 50
    sticky:
      cookie:
        name: ab_variant
        secure: true
        httpOnly: true
        maxAge: 86400     # 24 hours
```

---

## cert-manager Integration

### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

### ClusterIssuer for Let's Encrypt

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
            class: traefik
      # OR DNS-01 for wildcards:
      # - dns01:
      #     cloudflare:
      #       apiTokenSecretRef:
      #         name: cloudflare-api-token
      #         key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

### Certificate Resource

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webapp-cert
  namespace: default
spec:
  secretName: webapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - webapp.example.com
    - www.webapp.example.com
  # For wildcard:
  # dnsNames:
  #   - "*.example.com"
  #   - example.com
```

### Using cert-manager Certs with IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: webapp
  namespace: default
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`webapp.example.com`)
      kind: Rule
      services:
        - name: webapp-svc
          port: 80
  tls:
    secretName: webapp-tls      # Created by cert-manager Certificate
    # Do NOT use certResolver when using cert-manager
```

### Disable Traefik's Built-in ACME When Using cert-manager

```yaml
# Helm values — no certificatesResolvers needed
certificatesResolvers: {}

# cert-manager handles all certificate lifecycle
```

---

## RBAC Configuration

### ClusterRole for Traefik

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: traefik
rules:
  - apiGroups: [""]
    resources: [services, endpoints, secrets]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch]
  - apiGroups: [extensions, networking.k8s.io]
    resources: [ingresses, ingressclasses]
    verbs: [get, list, watch]
  - apiGroups: [extensions, networking.k8s.io]
    resources: [ingresses/status]
    verbs: [update]
  - apiGroups: [traefik.io]
    resources:
      - ingressroutes
      - ingressroutetcps
      - ingressrouteudps
      - middlewares
      - middlewaretcps
      - tlsoptions
      - tlsstores
      - traefikservices
      - serverstransports
      - serverstransporttcps
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: traefik
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik
subjects:
  - kind: ServiceAccount
    name: traefik
    namespace: traefik
```

---

## Cross-Namespace References

By default, Traefik CRDs can only reference resources in the same namespace.

### Enable Cross-Namespace

```yaml
# Helm values
providers:
  kubernetesCRD:
    allowCrossNamespace: true
```

### Reference Middleware from Another Namespace

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: webapp
  namespace: production
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`webapp.example.com`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik         # Middleware in 'traefik' namespace
        - name: rate-limit
          namespace: traefik
      services:
        - name: webapp-svc
          port: 80
  tls:
    certResolver: letsencrypt
```

---

## High Availability

### Multi-Replica Deployment

```yaml
# Helm values
deployment:
  replicas: 3

# ACME with HA — use cert-manager instead of built-in ACME
# Built-in ACME uses a file (acme.json) which doesn't support multi-replica
# Options:
# 1. Use cert-manager (recommended)
# 2. Use single replica for ACME + distribute certs via TLSStore
# 3. Use Traefik Enterprise with distributed ACME

persistence:
  enabled: true
  # For single-replica ACME only
  # Multi-replica must use cert-manager

# Pod disruption budget
podDisruptionBudget:
  enabled: true
  minAvailable: 1
  # OR
  # maxUnavailable: 1
```

### Leader Election for ACME

```yaml
# Helm values — use only if you must use built-in ACME with HA
# Only one pod will handle ACME challenges
providers:
  kubernetesCRD:
    enabled: true
  kubernetesIngress:
    enabled: true

# Use the Kubernetes leader election
# (Requires Traefik Enterprise for full distributed ACME)
```

---

## Monitoring in Kubernetes

### ServiceMonitor for Prometheus Operator

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: traefik
  namespace: monitoring
  labels:
    release: prometheus    # Match Prometheus operator selector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  namespaceSelector:
    matchNames: [traefik]
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
```

### Grafana Dashboard

Import dashboard ID **17346** (Traefik Official) from Grafana.com.

### PrometheusRule for Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: traefik-alerts
  namespace: monitoring
spec:
  groups:
    - name: traefik
      rules:
        - alert: TraefikHighErrorRate
          expr: |
            sum(rate(traefik_service_requests_total{code=~"5.."}[5m]))
            / sum(rate(traefik_service_requests_total[5m])) > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Traefik high 5xx error rate"
        - alert: TraefikCertExpiringSoon
          expr: |
            (traefik_tls_certs_not_after - time()) / 86400 < 14
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "TLS certificate expiring in less than 14 days"
        - alert: TraefikDown
          expr: up{job="traefik"} == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Traefik instance is down"
```

---

## Common Patterns

### Secured Dashboard

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`traefik.example.com`)
      kind: Rule
      middlewares:
        - name: dashboard-auth
        - name: ip-allowlist
      services:
        - name: api@internal
          kind: TraefikService
  tls:
    certResolver: letsencrypt
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-auth
  namespace: traefik
spec:
  basicAuth:
    secret: dashboard-auth-secret
```

### Catch-All Redirect (www → apex)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: www-redirect
  namespace: traefik
spec:
  redirectRegex:
    regex: "^https?://www\\.(.+)"
    replacement: "https://${1}"
    permanent: true
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: www-redirect
  namespace: default
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`www.example.com`)
      kind: Rule
      middlewares:
        - name: www-redirect
          namespace: traefik
      services:
        - name: noop@internal
          kind: TraefikService
  tls:
    certResolver: letsencrypt
```

### Multiple Services Behind One Domain

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: multi-service
  namespace: default
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      kind: Rule
      priority: 100
      middlewares:
        - name: strip-api-prefix
          namespace: traefik
      services:
        - name: api-svc
          port: 8080
    - match: Host(`app.example.com`) && PathPrefix(`/admin`)
      kind: Rule
      priority: 90
      middlewares:
        - name: basic-auth
          namespace: traefik
      services:
        - name: admin-svc
          port: 3000
    - match: Host(`app.example.com`)
      kind: Rule
      priority: 50
      services:
        - name: frontend-svc
          port: 80
  tls:
    certResolver: letsencrypt
```

---

## Migration from Ingress to IngressRoute

### Standard Ingress

```yaml
# Before: Standard Kubernetes Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
    traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - host: webapp.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webapp-svc
                port:
                  number: 80
  tls:
    - hosts: [webapp.example.com]
      secretName: webapp-tls
```

### Equivalent IngressRoute

```yaml
# After: Traefik IngressRoute CRD
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: webapp
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`webapp.example.com`)
      kind: Rule
      middlewares:
        - name: security-headers
          namespace: traefik
      services:
        - name: webapp-svc
          port: 80
  tls:
    certResolver: letsencrypt
```

**Migration benefits:**
- Richer rule syntax (`&&`, `||`, `HeadersRegexp`, `ClientIP`)
- TCP/UDP routing
- TraefikService for traffic splitting
- Middleware as reusable CRDs
- TLS options per route
