# Vault Kubernetes Integration Guide

## Table of Contents

- [Overview of Integration Methods](#overview-of-integration-methods)
- [Kubernetes Auth Method Setup](#kubernetes-auth-method-setup)
  - [Prerequisites](#prerequisites)
  - [Configuration](#configuration)
  - [Role Binding](#role-binding)
  - [Testing Authentication](#testing-authentication)
- [Vault Agent Injector](#vault-agent-injector)
  - [Installation](#injector-installation)
  - [Annotations Reference](#annotations-reference)
  - [Init-Container vs Sidecar Patterns](#init-container-vs-sidecar-patterns)
  - [Template Examples](#template-examples)
  - [Advanced Injection Patterns](#advanced-injection-patterns)
- [Vault CSI Provider](#vault-csi-provider)
  - [Installation](#csi-installation)
  - [SecretProviderClass Configuration](#secretproviderclass-configuration)
  - [Syncing to Kubernetes Secrets](#syncing-to-kubernetes-secrets)
  - [Auto-Rotation](#auto-rotation)
- [Vault Secrets Operator (VSO)](#vault-secrets-operator-vso)
  - [Installation](#vso-installation)
  - [VaultConnection and VaultAuth](#vaultconnection-and-vaultauth)
  - [VaultStaticSecret](#vaultstaticsecret)
  - [VaultDynamicSecret](#vaultdynamicsecret)
  - [VaultPKISecret](#vaultpkisecret)
  - [Secret Transformation](#secret-transformation)
  - [Rollout Restart Integration](#rollout-restart-integration)
- [Helm Chart Configuration](#helm-chart-configuration)
  - [Server Configuration](#server-configuration)
  - [Injector Configuration](#injector-configuration-1)
  - [CSI Configuration](#csi-configuration-1)
  - [HA with Raft](#ha-with-raft)
- [External Secrets Operator Integration](#external-secrets-operator-integration)
  - [Installation](#eso-installation)
  - [SecretStore Configuration](#secretstore-configuration)
  - [ExternalSecret Examples](#externalsecret-examples)
  - [ClusterSecretStore for Multi-Namespace](#clustersecretstore-for-multi-namespace)
- [Deployment Patterns](#deployment-patterns)
  - [Comparison Matrix](#comparison-matrix)
  - [Sidecar Pattern Deep Dive](#sidecar-pattern-deep-dive)
  - [Init-Container Pattern Deep Dive](#init-container-pattern-deep-dive)
  - [CSI Volume Pattern](#csi-volume-pattern)
  - [Operator Pattern](#operator-pattern)
- [Production Considerations](#production-considerations)
  - [Network Policies](#network-policies)
  - [Resource Limits](#resource-limits)
  - [Monitoring and Alerts](#monitoring-and-alerts)

---

## Overview of Integration Methods

| Method | Mechanism | Kubernetes Secret Created | Dynamic Secret Support | Auto-Rotation | Best For |
|--------|-----------|--------------------------|----------------------|---------------|----------|
| Agent Injector | Sidecar/Init container | No (files in shared volume) | Yes | Yes (sidecar) | Apps that read config files |
| CSI Provider | CSI volume mount | Optional (sync) | Limited | Yes | Apps using volume mounts |
| Secrets Operator (VSO) | Controller syncs to K8s Secrets | Yes | Yes (lease mgmt) | Yes | Native K8s Secret consumers |
| External Secrets Operator | Controller syncs to K8s Secrets | Yes | Limited | Yes (polling) | Multi-provider environments |

---

## Kubernetes Auth Method Setup

### Prerequisites

```bash
# 1. Vault is accessible from the Kubernetes cluster
# 2. ServiceAccount for Vault's token review exists

# Create a service account for Vault auth (if Vault is external)
kubectl create serviceaccount vault-auth -n vault

# Grant token review permissions
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: vault
EOF
```

### Configuration

```bash
# Get the JWT token for Vault's service account (Kubernetes 1.24+)
TOKEN_REVIEWER_JWT=$(kubectl create token vault-auth -n vault --duration=8760h)

# Get the Kubernetes API server CA certificate
K8S_CA_CERT=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

# Get the Kubernetes API server address
K8S_HOST=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.server}')

# Enable and configure Kubernetes auth in Vault
vault auth enable kubernetes

vault write auth/kubernetes/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT"

# If Vault runs inside K8s, use in-cluster config:
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
  # JWT and CA cert auto-discovered from pod's service account
```

### Role Binding

```bash
# Create a role binding a K8s service account to Vault policies
vault write auth/kubernetes/role/webapp \
  bound_service_account_names=webapp-sa \
  bound_service_account_namespaces=production,staging \
  policies=webapp-policy \
  ttl=1h \
  max_ttl=4h

# Wildcard namespace binding (use with caution)
vault write auth/kubernetes/role/monitoring \
  bound_service_account_names=monitoring-sa \
  bound_service_account_namespaces="*" \
  policies=monitoring-readonly \
  ttl=30m

# Multiple service accounts
vault write auth/kubernetes/role/shared-services \
  bound_service_account_names="svc-a,svc-b,svc-c" \
  bound_service_account_namespaces=shared \
  policies=shared-policy \
  ttl=1h
```

### Testing Authentication

```bash
# From a pod with the bound service account
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

# Login to Vault
curl -s --request POST \
  --data "{\"jwt\":\"$JWT\",\"role\":\"webapp\"}" \
  $VAULT_ADDR/v1/auth/kubernetes/login | jq .

# Or using vault CLI
vault write auth/kubernetes/login role=webapp jwt=$JWT
```

---

## Vault Agent Injector

The injector is a Kubernetes mutating admission webhook that injects Vault Agent as a sidecar or init container.

### Injector Installation

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --set "injector.enabled=true" \
  --set "injector.externalVaultAddr=https://vault.example.com:8200" \
  --set "server.enabled=false" \
  -n vault --create-namespace
```

### Annotations Reference

```yaml
# Core annotations
vault.hashicorp.com/agent-inject: "true"                    # Enable injection
vault.hashicorp.com/role: "webapp"                           # Vault K8s auth role
vault.hashicorp.com/agent-inject-status: "update"            # Re-inject on update

# Secret injection
vault.hashicorp.com/agent-inject-secret-config: "secret/data/webapp/config"
vault.hashicorp.com/agent-inject-template-config: |
  {{ with secret "secret/data/webapp/config" -}}
  export DB_HOST="{{ .Data.data.db_host }}"
  export DB_PORT="{{ .Data.data.db_port }}"
  {{- end }}

# File permissions
vault.hashicorp.com/agent-inject-perms-config: "0644"
vault.hashicorp.com/agent-inject-file-config: "app-config"   # Custom filename

# Command to run after render
vault.hashicorp.com/agent-inject-command-config: "/bin/sh -c 'kill -HUP $(pidof myapp)'"

# Agent configuration
vault.hashicorp.com/agent-pre-populate-only: "true"          # Init-only (no sidecar)
vault.hashicorp.com/agent-init-first: "true"                 # Init container runs first
vault.hashicorp.com/agent-cache-enable: "true"               # Enable caching proxy
vault.hashicorp.com/agent-cache-listener-port: "8200"        # Cache listener port
vault.hashicorp.com/agent-limits-cpu: "250m"
vault.hashicorp.com/agent-limits-mem: "128Mi"
vault.hashicorp.com/agent-requests-cpu: "50m"
vault.hashicorp.com/agent-requests-mem: "64Mi"

# TLS
vault.hashicorp.com/tls-skip-verify: "true"                  # Dev only
vault.hashicorp.com/ca-cert: "/vault/tls/ca.crt"

# Vault address (override global)
vault.hashicorp.com/agent-inject-vault-addr: "https://vault.example.com:8200"

# Namespace (Enterprise)
vault.hashicorp.com/namespace: "team-a"
```

### Init-Container vs Sidecar Patterns

**Init-Container Only** — Secrets fetched once at startup:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "webapp"
        vault.hashicorp.com/agent-pre-populate-only: "true"    # Init-only
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/webapp"
        vault.hashicorp.com/agent-inject-template-db: |
          {{ with secret "database/creds/webapp" -}}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{- end }}
    spec:
      serviceAccountName: webapp-sa
      containers:
      - name: webapp
        image: myapp:latest
        command: ["/bin/sh", "-c", "source /vault/secrets/db && exec ./app"]
```

**Sidecar** — Continuous renewal and rotation:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "webapp"
        # Sidecar is default (no agent-pre-populate-only)
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/webapp"
        vault.hashicorp.com/agent-inject-template-db: |
          {{ with secret "database/creds/webapp" -}}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{- end }}
        vault.hashicorp.com/agent-inject-command-db: "/bin/sh -c 'kill -HUP 1'"
    spec:
      serviceAccountName: webapp-sa
      containers:
      - name: webapp
        image: myapp:latest
```

### Template Examples

```yaml
# JSON config file
vault.hashicorp.com/agent-inject-template-config: |
  {{ with secret "secret/data/webapp/config" -}}
  {
    "database": {
      "host": "{{ .Data.data.db_host }}",
      "port": {{ .Data.data.db_port }}
    },
    "api_key": "{{ .Data.data.api_key }}"
  }
  {{- end }}

# TLS certificate files
vault.hashicorp.com/agent-inject-secret-cert: "pki/issue/webapp"
vault.hashicorp.com/agent-inject-template-cert: |
  {{ with secret "pki/issue/webapp" "common_name=webapp.example.com" "ttl=24h" -}}
  {{ .Data.certificate }}
  {{ .Data.issuing_ca }}
  {{- end }}

vault.hashicorp.com/agent-inject-secret-key: "pki/issue/webapp"
vault.hashicorp.com/agent-inject-template-key: |
  {{ with secret "pki/issue/webapp" "common_name=webapp.example.com" "ttl=24h" -}}
  {{ .Data.private_key }}
  {{- end }}

# .env file with multiple secrets
vault.hashicorp.com/agent-inject-template-env: |
  {{ with secret "secret/data/webapp/config" -}}
  {{ range $k, $v := .Data.data -}}
  {{ $k }}={{ $v }}
  {{ end -}}
  {{- end }}
```

### Advanced Injection Patterns

**Multiple Vault Paths:**

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "webapp"
  vault.hashicorp.com/agent-inject-secret-db: "database/creds/webapp"
  vault.hashicorp.com/agent-inject-secret-config: "secret/data/webapp/config"
  vault.hashicorp.com/agent-inject-secret-cert: "pki/issue/webapp"
```

**Caching Proxy Pattern:**

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "webapp"
  vault.hashicorp.com/agent-cache-enable: "true"
  vault.hashicorp.com/agent-cache-listener-port: "8200"
  # App can use http://localhost:8200 as VAULT_ADDR
  # Agent handles auth and caching transparently
```

---

## Vault CSI Provider

The Secrets Store CSI driver mounts secrets as volumes into pods.

### CSI Installation

```bash
# Install Secrets Store CSI Driver
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  -n kube-system

# Install Vault CSI Provider
helm install vault hashicorp/vault \
  --set "server.enabled=false" \
  --set "injector.enabled=false" \
  --set "csi.enabled=true" \
  -n vault --create-namespace
```

### SecretProviderClass Configuration

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-webapp-secrets
  namespace: production
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.example.com:8200"
    roleName: "webapp"
    objects: |
      - objectName: "db-username"
        secretPath: "database/creds/webapp"
        secretKey: "username"
      - objectName: "db-password"
        secretPath: "database/creds/webapp"
        secretKey: "password"
      - objectName: "api-key"
        secretPath: "secret/data/webapp/config"
        secretKey: "api_key"
```

**Pod using CSI volume:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: webapp
spec:
  serviceAccountName: webapp-sa
  containers:
  - name: webapp
    image: myapp:latest
    volumeMounts:
    - name: vault-secrets
      mountPath: "/mnt/secrets"
      readOnly: true
    # Files at /mnt/secrets/db-username, /mnt/secrets/db-password, etc.
  volumes:
  - name: vault-secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "vault-webapp-secrets"
```

### Syncing to Kubernetes Secrets

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-webapp-secrets
spec:
  provider: vault
  parameters:
    roleName: "webapp"
    vaultAddress: "https://vault.example.com:8200"
    objects: |
      - objectName: "db-username"
        secretPath: "database/creds/webapp"
        secretKey: "username"
      - objectName: "db-password"
        secretPath: "database/creds/webapp"
        secretKey: "password"
  secretObjects:
  - secretName: webapp-db-secret
    type: Opaque
    data:
    - objectName: db-username
      key: username
    - objectName: db-password
      key: password
```

### Auto-Rotation

```bash
# Enable rotation in CSI driver
helm upgrade csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --set enableSecretRotation=true \
  --set rotationPollInterval=120s \
  -n kube-system
```

---

## Vault Secrets Operator (VSO)

VSO is HashiCorp's recommended Kubernetes-native approach. It syncs Vault secrets to Kubernetes Secrets via CRDs.

### VSO Installation

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version 0.9.0 \
  -n vault-secrets-operator-system --create-namespace \
  --set "defaultVaultConnection.enabled=true" \
  --set "defaultVaultConnection.address=https://vault.example.com:8200"
```

### VaultConnection and VaultAuth

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: production
spec:
  address: "https://vault.example.com:8200"
  skipTLSVerify: false
  caCertSecretRef: vault-ca-cert  # Optional: K8s secret with CA cert
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: vault-auth
  namespace: production
spec:
  method: kubernetes
  mount: kubernetes
  vaultConnectionRef: vault-connection
  kubernetes:
    role: webapp
    serviceAccount: webapp-sa
    audiences:
    - vault
```

### VaultStaticSecret

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: webapp-config
  namespace: production
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: webapp/config
  type: kv-v2
  refreshAfter: 30s
  destination:
    name: webapp-k8s-secret
    create: true
    labels:
      app: webapp
    transformation:
      excludeRaw: true
      templates:
        # Transform secret keys
        config.json: |
          {
            "database_url": "postgres://{{ get .Secrets "db_user" }}:{{ get .Secrets "db_pass" }}@db:5432/app"
          }
  rolloutRestartTargets:
  - kind: Deployment
    name: webapp
```

### VaultDynamicSecret

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: webapp-db-creds
  namespace: production
spec:
  vaultAuthRef: vault-auth
  mount: database
  path: creds/webapp
  renewalPercent: 67     # Renew when 67% of lease has elapsed
  revoke: true           # Revoke on CRD deletion
  destination:
    name: webapp-db-secret
    create: true
  rolloutRestartTargets:
  - kind: Deployment
    name: webapp
```

### VaultPKISecret

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultPKISecret
metadata:
  name: webapp-tls
  namespace: production
spec:
  vaultAuthRef: vault-auth
  mount: pki
  role: webapp-certs
  commonName: webapp.example.com
  altNames:
  - webapp.production.svc.cluster.local
  ttl: 24h
  expiryOffset: 1h       # Renew 1h before expiry
  destination:
    name: webapp-tls-secret
    create: true
    type: kubernetes.io/tls
  rolloutRestartTargets:
  - kind: Deployment
    name: webapp
```

### Secret Transformation

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: webapp-config
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: webapp/config
  type: kv-v2
  refreshAfter: 60s
  destination:
    name: webapp-k8s-secret
    create: true
    transformation:
      excludeRaw: true    # Don't include raw Vault keys
      excludes:           # Exclude specific keys
      - internal_key
      includes:           # Only include specific keys (mutually exclusive with excludes)
      - db_host
      - db_port
      templates:
        # Generate composite values
        DATABASE_URL: |
          postgresql://{{ get .Secrets "db_user" }}:{{ get .Secrets "db_pass" }}@{{ get .Secrets "db_host" }}:{{ get .Secrets "db_port" }}/{{ get .Secrets "db_name" }}
        .env: |
          {{- range $key, $value := .Secrets }}
          {{ $key }}={{ $value }}
          {{- end }}
```

### Rollout Restart Integration

VSO can automatically restart deployments when secrets change:

```yaml
spec:
  rolloutRestartTargets:
  - kind: Deployment
    name: webapp
  - kind: StatefulSet
    name: webapp-workers
  - kind: DaemonSet
    name: webapp-agent
```

---

## Helm Chart Configuration

### Server Configuration

```yaml
# values.yaml for Vault server on Kubernetes
server:
  enabled: true
  image:
    repository: hashicorp/vault
    tag: "1.18.3"

  resources:
    requests:
      memory: 256Mi
      cpu: 250m
    limits:
      memory: 512Mi
      cpu: 500m

  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/tls/tls.crt"
          tls_key_file  = "/vault/tls/tls.key"
        }
        storage "raft" {
          path = "/vault/data"
          retry_join {
            leader_api_addr = "https://vault-0.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/ca.crt"
          }
          retry_join {
            leader_api_addr = "https://vault-1.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/ca.crt"
          }
          retry_join {
            leader_api_addr = "https://vault-2.vault-internal:8200"
            leader_ca_cert_file = "/vault/tls/ca.crt"
          }
        }
        seal "awskms" {
          region     = "us-east-1"
          kms_key_id = "alias/vault-unseal"
        }
        service_registration "kubernetes" {}

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: gp3

  auditStorage:
    enabled: true
    size: 20Gi
    storageClass: gp3

  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
    - host: vault.example.com
    tls:
    - hosts:
      - vault.example.com
      secretName: vault-tls

  serviceAccount:
    create: true
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/vault-kms-role
```

### Injector Configuration

```yaml
injector:
  enabled: true
  replicas: 2
  resources:
    requests:
      memory: 64Mi
      cpu: 50m
    limits:
      memory: 128Mi
      cpu: 250m
  agentDefaults:
    cpuLimit: 250m
    cpuRequest: 50m
    memLimit: 128Mi
    memRequest: 64Mi
    template: map
    templateConfig:
      exitOnRetryFailure: true
      staticSecretRenderInterval: 30s
```

### CSI Configuration

```yaml
csi:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 250m
      memory: 128Mi
```

### HA with Raft

```bash
# Install HA Vault with Raft
helm install vault hashicorp/vault \
  -f values.yaml \
  -n vault --create-namespace

# Initialize the first node
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json

# Unseal all nodes (if not using auto-unseal)
for i in 0 1 2; do
  kubectl exec -n vault vault-$i -- vault operator unseal <key1>
  kubectl exec -n vault vault-$i -- vault operator unseal <key2>
  kubectl exec -n vault vault-$i -- vault operator unseal <key3>
done

# Join peers to cluster
kubectl exec -n vault vault-1 -- vault operator raft join \
  https://vault-0.vault-internal:8200
kubectl exec -n vault vault-2 -- vault operator raft join \
  https://vault-0.vault-internal:8200

# Verify
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

---

## External Secrets Operator Integration

The External Secrets Operator (ESO) is a community project that supports multiple secret providers including Vault.

### ESO Installation

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true
```

### SecretStore Configuration

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-store
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.example.com:8200"
      path: "secret"
      version: "v2"
      namespace: "team-a"   # Vault namespace (Enterprise)
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "webapp"
          serviceAccountRef:
            name: webapp-sa
      # Or AppRole auth:
      # auth:
      #   appRole:
      #     path: "approle"
      #     roleId: "db02de05-fa39-4855-059b-67221c5c2f63"
      #     secretRef:
      #       name: approle-secret
      #       key: secret-id
```

### ExternalSecret Examples

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: webapp-config
  namespace: production
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-store
    kind: SecretStore
  target:
    name: webapp-k8s-secret
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      type: Opaque
      data:
        DATABASE_URL: "postgresql://{{ .db_user }}:{{ .db_pass }}@{{ .db_host }}:5432/app"
  data:
  - secretKey: db_user
    remoteRef:
      key: secret/data/webapp/config
      property: db_user
  - secretKey: db_pass
    remoteRef:
      key: secret/data/webapp/config
      property: db_pass
  - secretKey: db_host
    remoteRef:
      key: secret/data/webapp/config
      property: db_host
---
# Fetch all keys from a path
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: webapp-all-config
  namespace: production
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-store
    kind: SecretStore
  target:
    name: webapp-all-secrets
    creationPolicy: Owner
  dataFrom:
  - extract:
      key: secret/data/webapp/config
```

### ClusterSecretStore for Multi-Namespace

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-global
spec:
  provider:
    vault:
      server: "https://vault.example.com:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
# Use from any namespace
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: shared-config
  namespace: team-b
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-global
    kind: ClusterSecretStore
  target:
    name: shared-k8s-secret
  dataFrom:
  - extract:
      key: secret/data/shared/config
```

---

## Deployment Patterns

### Comparison Matrix

| Consideration | Agent Injector | CSI Provider | VSO | ESO |
|--------------|---------------|-------------|-----|-----|
| K8s Secret created | No | Optional | Yes | Yes |
| Sidecar required | Yes (or init) | No | No | No |
| Pod resource overhead | Medium | Low | None | None |
| Dynamic secrets | Full | Limited | Full | Limited |
| Lease management | Agent handles | Manual | Operator handles | Manual |
| Multi-provider | No | No | No | Yes |
| Secret templating | Consul Template | No | Go templates | Go templates |
| Rollout restart | Manual | Manual | Built-in | Built-in |
| CRD-based | No | Yes | Yes | Yes |

### Sidecar Pattern Deep Dive

Best for: Dynamic secrets requiring continuous renewal, apps reading from files.

```yaml
# Full sidecar example with database credentials
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "webapp"
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/webapp"
        vault.hashicorp.com/agent-inject-template-db: |
          {{ with secret "database/creds/webapp" -}}
          export DB_USER="{{ .Data.username }}"
          export DB_PASS="{{ .Data.password }}"
          {{- end }}
        vault.hashicorp.com/agent-inject-command-db: |
          /bin/sh -c "kill -HUP $(pidof myapp) 2>/dev/null || true"
        vault.hashicorp.com/agent-limits-cpu: "250m"
        vault.hashicorp.com/agent-limits-mem: "128Mi"
    spec:
      serviceAccountName: webapp-sa
      containers:
      - name: webapp
        image: myapp:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          source /vault/secrets/db
          exec ./myapp
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
```

### Init-Container Pattern Deep Dive

Best for: Static secrets, batch jobs, one-time credential fetch.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "db-migration"
        vault.hashicorp.com/agent-pre-populate-only: "true"
        vault.hashicorp.com/agent-inject-secret-db: "database/creds/migration"
        vault.hashicorp.com/agent-inject-template-db: |
          {{ with secret "database/creds/migration" -}}
          DB_USER={{ .Data.username }}
          DB_PASS={{ .Data.password }}
          {{- end }}
    spec:
      serviceAccountName: migration-sa
      restartPolicy: Never
      containers:
      - name: migrate
        image: migrate:latest
        command: ["/bin/sh", "-c"]
        args: ["source /vault/secrets/db && migrate -database $DB_URL up"]
```

### CSI Volume Pattern

Best for: Apps using file-based secrets, no sidecar overhead desired.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  template:
    spec:
      serviceAccountName: webapp-sa
      containers:
      - name: webapp
        image: myapp:latest
        volumeMounts:
        - name: secrets
          mountPath: "/mnt/secrets"
          readOnly: true
        env:
        - name: DB_USER_FILE
          value: "/mnt/secrets/db-username"
        - name: DB_PASS_FILE
          value: "/mnt/secrets/db-password"
      volumes:
      - name: secrets
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "vault-webapp-secrets"
```

### Operator Pattern

Best for: Native Kubernetes Secret consumers, GitOps workflows.

```yaml
# VSO manages the lifecycle — just declare what you need
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: webapp-config
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: webapp/config
  type: kv-v2
  refreshAfter: 30s
  destination:
    name: webapp-secret
    create: true
  rolloutRestartTargets:
  - kind: Deployment
    name: webapp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  template:
    spec:
      containers:
      - name: webapp
        envFrom:
        - secretRef:
            name: webapp-secret    # Standard K8s secret reference
```

---

## Production Considerations

### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-vault-access
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: webapp
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: vault
    ports:
    - port: 8200
      protocol: TCP
---
# Allow injector webhook traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-injector-webhook
  namespace: vault
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vault-agent-injector
  policyTypes:
  - Ingress
  ingress:
  - from: []   # kube-apiserver needs access
    ports:
    - port: 8080
      protocol: TCP
```

### Resource Limits

```yaml
# Recommended resource limits for Vault components
# Vault Server
server:
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 2000m, memory: 1Gi }

# Agent Injector
injector:
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { cpu: 250m, memory: 128Mi }

# Per-pod Agent (via annotations)
# vault.hashicorp.com/agent-requests-cpu: "50m"
# vault.hashicorp.com/agent-requests-mem: "64Mi"
# vault.hashicorp.com/agent-limits-cpu: "250m"
# vault.hashicorp.com/agent-limits-mem: "128Mi"
```

### Monitoring and Alerts

```yaml
# Prometheus ServiceMonitor for Vault
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: vault
  namespace: vault
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: vault
  endpoints:
  - port: http
    path: /v1/sys/metrics
    params:
      format: ["prometheus"]
    bearerTokenSecret:
      name: vault-prometheus-token
      key: token
    interval: 30s
---
# Key alerts
# - VaultSealed: vault_core_unsealed == 0
# - VaultLeaderLost: changes(vault_core_leadership_setup_failed) > 0
# - VaultHighLatency: vault_core_handle_request{quantile="0.99"} > 1
# - VaultTooManyLeases: vault_expire_num_leases > 100000
# - VaultAuditFailure: vault_audit_log_request_failure > 0
```
