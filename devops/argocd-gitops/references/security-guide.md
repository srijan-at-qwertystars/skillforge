# Argo CD Security Guide

## Table of Contents

- [RBAC Policy Configuration](#rbac-policy-configuration)
  - [Policy Syntax](#policy-syntax)
  - [AppProject Roles and JWT Tokens](#appproject-roles-and-jwt-tokens)
  - [Fine-Grained Permissions](#fine-grained-permissions)
  - [Default Policies and Scopes](#default-policies-and-scopes)
- [SSO Setup](#sso-setup)
  - [OIDC Direct Integration](#oidc-direct-integration)
  - [Dex Connector](#dex-connector)
  - [Azure AD (Entra ID)](#azure-ad-entra-id)
  - [Okta](#okta)
  - [Group Claims and Scopes](#group-claims-and-scopes)
- [Secrets Management](#secrets-management)
  - [Sealed Secrets](#sealed-secrets)
  - [External Secrets Operator](#external-secrets-operator)
  - [SOPS Integration](#sops-integration)
  - [HashiCorp Vault](#hashicorp-vault)
  - [Comparison and Recommendations](#comparison-and-recommendations)
- [Network Policies for Argo CD Components](#network-policies-for-argo-cd-components)
  - [Component Communication Map](#component-communication-map)
  - [Network Policy Manifests](#network-policy-manifests)
- [Audit Logging](#audit-logging)
  - [Enabling Audit Logs](#enabling-audit-logs)
  - [Log Forwarding](#log-forwarding)
  - [Monitoring Suspicious Activity](#monitoring-suspicious-activity)
- [Supply Chain Security](#supply-chain-security)
  - [Image Signing and Verification](#image-signing-and-verification)
  - [Attestation with SLSA](#attestation-with-slsa)
  - [Manifest Verification with GPG](#manifest-verification-with-gpg)
  - [Hardening the Argo CD Installation](#hardening-the-argo-cd-installation)

---

## RBAC Policy Configuration

### Policy Syntax

Argo CD RBAC uses a Casbin-based policy model. Policies are configured in the `argocd-rbac-cm` ConfigMap.

```
p, <subject>, <resource>, <action>, <object>, <effect>
g, <subject>, <role>
```

- **subject**: user, group, or role
- **resource**: `applications`, `clusters`, `repositories`, `certificates`, `accounts`, `gpgkeys`, `logs`, `exec`, `extensions`
- **action**: `get`, `create`, `update`, `delete`, `sync`, `override`, `action/*`, `*`
- **object**: `<project>/<application>` or `*`
- **effect**: `allow` or `deny`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  # Default policy for authenticated users with no matching rules
  policy.default: role:readonly

  # CSV-formatted policy rules
  policy.csv: |
    # Roles
    p, role:org-admin, applications, *, */*, allow
    p, role:org-admin, clusters, *, *, allow
    p, role:org-admin, repositories, *, *, allow
    p, role:org-admin, certificates, *, *, allow
    p, role:org-admin, accounts, *, *, allow
    p, role:org-admin, gpgkeys, *, *, allow
    p, role:org-admin, logs, get, */*, allow
    p, role:org-admin, exec, create, */*, allow

    # Read-only role
    p, role:readonly, applications, get, */*, allow
    p, role:readonly, clusters, get, *, allow
    p, role:readonly, repositories, get, *, allow
    p, role:readonly, certificates, get, *, allow
    p, role:readonly, logs, get, */*, allow

    # Developer role — view and sync only
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    p, role:developer, logs, get, */*, allow

    # Map SSO groups to roles
    g, my-org:platform-team, role:org-admin
    g, my-org:developers, role:developer

  # Scopes to use for group claims from OIDC tokens
  scopes: '[groups, email]'

  # Match SSO groups case-insensitively
  policy.matchMode: glob
```

### AppProject Roles and JWT Tokens

Project-scoped roles allow fine-grained access per project, with JWT tokens for CI/CD automation:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-backend
  namespace: argocd
spec:
  roles:
    - name: ci-deployer
      description: "CI/CD service account for automated deployments"
      policies:
        - p, proj:team-backend:ci-deployer, applications, sync, team-backend/*, allow
        - p, proj:team-backend:ci-deployer, applications, get, team-backend/*, allow
        - p, proj:team-backend:ci-deployer, applications, override, team-backend/*, allow
      # JWT tokens for programmatic access
      jwtTokens:
        - iat: 1693000000
          id: ci-token-1

    - name: viewer
      description: "Read-only access for stakeholders"
      policies:
        - p, proj:team-backend:viewer, applications, get, team-backend/*, allow
        - p, proj:team-backend:viewer, logs, get, team-backend/*, allow
      groups:
        - org:backend-stakeholders
```

**Generate and manage JWT tokens:**
```bash
# Create a project token
argocd proj role create-token team-backend ci-deployer --token-id ci-token-1

# List tokens
argocd proj role list-tokens team-backend ci-deployer

# Delete a token
argocd proj role delete-token team-backend ci-deployer ci-token-1

# Use token in CI/CD
export ARGOCD_AUTH_TOKEN="<token>"
argocd app sync my-app --auth-token "$ARGOCD_AUTH_TOKEN" --server argocd.example.com
```

### Fine-Grained Permissions

```yaml
policy.csv: |
  # Allow team to manage only their apps in their project
  p, role:team-a-dev, applications, get, team-a/*, allow
  p, role:team-a-dev, applications, sync, team-a/*, allow
  p, role:team-a-dev, applications, create, team-a/*, allow
  p, role:team-a-dev, applications, delete, team-a/*, allow

  # Allow viewing logs but not exec
  p, role:team-a-dev, logs, get, team-a/*, allow
  # p, role:team-a-dev, exec, create, team-a/*, deny  # Explicit deny

  # Restrict specific app actions (glob patterns)
  p, role:team-a-dev, applications, sync, team-a/production-*, deny

  # Allow specific actions on custom resources
  p, role:team-a-dev, applications, action/argoproj.io/Rollout/resume, team-a/*, allow
  p, role:team-a-dev, applications, action/argoproj.io/Rollout/promote-full, team-a/*, allow
```

### Default Policies and Scopes

```yaml
data:
  # What unauthenticated/unmapped users can do
  policy.default: ''              # No access (most secure)
  # policy.default: role:readonly  # Read-only (common for internal)

  # Which OIDC claims to use for group matching
  scopes: '[groups]'              # Default: groups claim
  # scopes: '[groups, email, cognito:groups]'  # Multiple claims

  # Built-in admin account (disable in production)
  # In argocd-cm:
  admin.enabled: "false"
```

---

## SSO Setup

### OIDC Direct Integration

Configure directly in `argocd-cm` without Dex:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.example.com

  oidc.config: |
    name: SSO
    issuer: https://accounts.google.com
    clientID: xxxxxxxxxxxx.apps.googleusercontent.com
    clientSecret: $oidc.google.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
    requestedIDTokenClaims:
      groups:
        essential: true
```

Store the client secret in `argocd-secret`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
stringData:
  oidc.google.clientSecret: "GOCSPX-xxxxxxxxxxxx"
```

### Dex Connector

Dex acts as a federated identity broker, supporting many identity providers:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.example.com
  dex.config: |
    connectors:
      # GitHub connector
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientID
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: my-org
              teams:
                - platform-team
                - developers
          loadAllGroups: false

      # LDAP connector
      - type: ldap
        id: ldap
        name: Corporate LDAP
        config:
          host: ldap.example.com:636
          insecureNoSSL: false
          insecureSkipVerify: false
          rootCA: /etc/ssl/certs/ldap-ca.pem
          bindDN: cn=argocd,ou=services,dc=example,dc=com
          bindPW: $dex.ldap.bindPW
          userSearch:
            baseDN: ou=users,dc=example,dc=com
            filter: "(objectClass=person)"
            username: uid
            idAttr: uid
            emailAttr: mail
            nameAttr: cn
          groupSearch:
            baseDN: ou=groups,dc=example,dc=com
            filter: "(objectClass=groupOfNames)"
            userMatchers:
              - userAttr: DN
                groupAttr: member
            nameAttr: cn
```

### Azure AD (Entra ID)

```yaml
# argocd-cm
data:
  url: https://argocd.example.com
  oidc.config: |
    name: Azure AD
    issuer: https://login.microsoftonline.com/<TENANT_ID>/v2.0
    clientID: <APPLICATION_CLIENT_ID>
    clientSecret: $oidc.azure.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
    requestedIDTokenClaims:
      groups:
        essential: true
    # Azure AD returns group OIDs by default
    # Map OIDs to names in RBAC policy
```

Azure AD app registration requirements:
1. Register an application in Azure AD
2. Set redirect URI: `https://argocd.example.com/auth/callback`
3. Add `GroupMember.Read.All` API permission
4. Configure token claims to include `groups`
5. Create a client secret

```yaml
# argocd-rbac-cm — map Azure AD group OIDs
data:
  policy.csv: |
    g, "12345678-abcd-efgh-ijkl-123456789abc", role:org-admin
    g, "87654321-dcba-hgfe-lkji-cba987654321", role:developer
```

### Okta

```yaml
# argocd-cm
data:
  url: https://argocd.example.com
  oidc.config: |
    name: Okta
    issuer: https://myorg.okta.com/oauth2/default
    clientID: <OKTA_CLIENT_ID>
    clientSecret: $oidc.okta.clientSecret
    requestedScopes:
      - openid
      - profile
      - email
      - groups
    requestedIDTokenClaims:
      groups:
        essential: true
```

Okta configuration:
1. Create an OIDC application in Okta (Web type)
2. Set sign-in redirect URI: `https://argocd.example.com/auth/callback`
3. Assign users/groups to the application
4. Add a `groups` claim to the ID token (Security → API → Authorization Servers → Claims)

### Group Claims and Scopes

**Critical**: Ensure the OIDC provider includes group information in tokens:

```yaml
# In argocd-rbac-cm
data:
  # Must match the claim name used by your OIDC provider
  scopes: '[groups]'

  # Some providers use different claim names:
  # scopes: '[cognito:groups]'     # AWS Cognito
  # scopes: '[roles]'              # Some Keycloak configs
  # scopes: '[groups, email]'      # Multiple claims
```

**Debug group claims:**
```bash
# Decode JWT token to verify groups claim
argocd account get-user-info
# Or decode the token manually:
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

---

## Secrets Management

### Sealed Secrets

Bitnami Sealed Secrets encrypts secrets client-side; only the controller in-cluster can decrypt.

```bash
# Install Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Install kubeseal CLI
# (platform-specific installation)

# Create a sealed secret
kubectl create secret generic db-creds \
  --from-literal=username=admin \
  --from-literal=password=s3cret \
  --dry-run=client -o yaml | \
  kubeseal --format yaml --controller-namespace kube-system > sealed-db-creds.yaml
```

```yaml
# Commit this to Git — safe, encrypted
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-creds
  namespace: my-app
spec:
  encryptedData:
    username: AgBz8...
    password: AgCJ7...
  template:
    metadata:
      name: db-creds
    type: Opaque
```

**Considerations:**
- Sealed Secrets are cluster-scoped by default (can only be decrypted in the same cluster)
- Rotate the sealing key periodically
- Back up the controller's private key for disaster recovery
- Use `--scope cluster-wide` for multi-namespace secrets

### External Secrets Operator

ESO syncs secrets from external providers into Kubernetes:

```bash
# Install ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

```yaml
# ClusterSecretStore — connect to AWS Secrets Manager
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets

---
# ExternalSecret — sync specific secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: app-secrets
    creationPolicy: Owner
    template:
      type: Opaque
      data:
        DB_HOST: "{{ .db_host }}"
        DB_PASSWORD: "{{ .db_password }}"
  data:
    - secretKey: db_host
      remoteRef:
        key: prod/myapp/database
        property: host
    - secretKey: db_password
      remoteRef:
        key: prod/myapp/database
        property: password
```

**Argo CD integration**: Commit `ExternalSecret` CRDs to Git. Argo CD deploys them, ESO syncs the actual secrets. Argo CD never sees plaintext.

### SOPS Integration

Mozilla SOPS encrypts YAML/JSON values in-place. Use as a Config Management Plugin:

```yaml
# Encrypt a file
sops --encrypt --age age1... --in-place secrets.yaml

# The file looks like:
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
stringData:
  password: ENC[AES256_GCM,data:...,type:str]
sops:
  kms: []
  age:
    - recipient: age1...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

**CMP sidecar for SOPS:**
```yaml
# plugin.yaml
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: sops-kustomize
spec:
  generate:
    command: ["/bin/sh", "-c"]
    args:
      - |
        # Decrypt all encrypted files
        for f in $(find . -name '*.enc.yaml' -o -name '*.enc.json'); do
          sops -d "$f" > "${f%.enc.*}.yaml"
        done
        # Build with Kustomize
        kustomize build .
  discover:
    find:
      glob: "**/*.enc.yaml"
```

**Security note**: SOPS-decrypted values pass through repo-server memory and may be cached in Redis. For maximum security, prefer External Secrets Operator.

### HashiCorp Vault

**Option 1: Vault Agent Injector** — inject secrets as files into pods:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "my-app"
        vault.hashicorp.com/agent-inject-secret-db-creds: "secret/data/my-app/db"
        vault.hashicorp.com/agent-inject-template-db-creds: |
          {{- with secret "secret/data/my-app/db" -}}
          export DB_HOST={{ .Data.data.host }}
          export DB_PASSWORD={{ .Data.data.password }}
          {{- end -}}
```

**Option 2: External Secrets Operator with Vault:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: https://vault.example.com
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

**Option 3: Argo CD Vault Plugin (AVP)** — replace placeholders in manifests:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  annotations:
    avp.kubernetes.io/path: "secret/data/my-app"
stringData:
  password: <password>    # Replaced at render time with Vault value
```

### Comparison and Recommendations

| Method | Secrets in Git | Runtime Dependency | Rotation | Complexity |
|--------|---------------|-------------------|----------|------------|
| Sealed Secrets | Encrypted | Controller only | Manual re-seal | Low |
| External Secrets | CRD only | ESO + Provider | Automatic | Medium |
| SOPS | Encrypted | CMP sidecar | Manual re-encrypt | Medium |
| Vault (AVP) | Placeholders | Vault + AVP | Via Vault | High |
| Vault (Injector) | None | Vault + Injector | Via Vault | High |

**Recommendations:**
- **Small teams**: Sealed Secrets (simplest)
- **Cloud-native orgs**: External Secrets Operator (best balance)
- **Enterprise with Vault**: ESO + Vault backend or Vault Injector
- **Avoid**: SOPS for high-security (secrets pass through repo-server cache)

---

## Network Policies for Argo CD Components

### Component Communication Map

```
Internet → Ingress → argocd-server (443/80)
argocd-server → argocd-repo-server (8081)
argocd-server → argocd-redis (6379)
argocd-server → argocd-dex-server (5556/5557)
argocd-server → Kubernetes API (6443)
argocd-application-controller → argocd-repo-server (8081)
argocd-application-controller → argocd-redis (6379)
argocd-application-controller → Kubernetes API (6443)
argocd-application-controller → target cluster APIs (6443)
argocd-repo-server → Git repos (443/22)
argocd-repo-server → Helm registries (443)
argocd-applicationset-controller → argocd-repo-server (8081)
argocd-applicationset-controller → SCM providers (443)
argocd-notifications-controller → argocd-redis (6379)
argocd-notifications-controller → notification targets (443)
```

### Network Policy Manifests

```yaml
# Restrict argocd-repo-server: only accept from server and controller
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-repo-server
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: repo-server
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: server
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: applicationset-controller
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-application-controller
      ports:
        - port: 8081
          protocol: TCP
  egress:
    # Git/Helm repos
    - to: []
      ports:
        - port: 443
          protocol: TCP
        - port: 22
          protocol: TCP
        - port: 80
          protocol: TCP
    # DNS
    - to: []
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP

---
# Restrict Redis: only from server, controller, notifications
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-redis
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: redis
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: server
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: argocd-application-controller
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: notifications-controller
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: repo-server
      ports:
        - port: 6379
          protocol: TCP

---
# Restrict argocd-server: accept from ingress and internal components
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-server
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: server
  policyTypes:
    - Ingress
  ingress:
    # From ingress controller
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
          protocol: TCP
        - port: 8083
          protocol: TCP
    # From within argocd namespace (CLI, other components)
    - from:
        - podSelector: {}
      ports:
        - port: 8080
          protocol: TCP
```

---

## Audit Logging

### Enabling Audit Logs

Argo CD logs all API actions. Configure verbosity in `argocd-cmd-params-cm`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Server log level
  server.log.level: info

  # Log format (json recommended for parsing)
  server.log.format: json

  # Enable gRPC access logging
  server.grpc.log: "true"
```

Audit events include:
- Application create/update/delete/sync
- Project create/update/delete
- Repository add/remove
- Cluster add/remove
- User login/logout
- RBAC policy changes

### Log Forwarding

**To ELK/OpenSearch:**
```yaml
# Fluent Bit sidecar or DaemonSet config
[INPUT]
    Name              tail
    Path              /var/log/containers/argocd-server-*.log
    Parser            docker
    Tag               argocd.server

[FILTER]
    Name              parser
    Match             argocd.*
    Key_Name          log
    Parser            json

[OUTPUT]
    Name              es
    Match             argocd.*
    Host              elasticsearch.logging
    Port              9200
    Index             argocd-audit
    Type              _doc
```

**To Loki (Grafana):**
```yaml
# Promtail config
scrape_configs:
  - job_name: argocd
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [argocd]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_part_of]
        regex: argocd
        action: keep
    pipeline_stages:
      - json:
          expressions:
            level: level
            msg: msg
            user: grpc.request.claims.sub
```

### Monitoring Suspicious Activity

Key events to alert on:

```yaml
# Prometheus alerting rules
groups:
  - name: argocd-security
    rules:
      - alert: ArgoCD_UnauthorizedAccess
        expr: |
          sum(rate(argocd_app_k8s_request_total{response_code=~"401|403"}[5m])) > 0
        for: 5m
        annotations:
          summary: "Unauthorized access attempts detected"

      - alert: ArgoCD_AdminLoginUsed
        expr: |
          sum(rate(argocd_app_k8s_request_total{username="admin"}[5m])) > 0
        for: 1m
        annotations:
          summary: "Admin account login detected (should be disabled)"

      - alert: ArgoCD_SyncToProtectedNamespace
        expr: |
          argocd_app_info{dest_namespace=~"kube-system|argocd|cert-manager"} > 0
        annotations:
          summary: "Application syncing to protected namespace"
```

**Log queries for investigation:**
```bash
# Find all sync operations by user
kubectl logs -n argocd deploy/argocd-server --since=24h | \
  jq 'select(.msg == "sync" or .msg == "update") | {time: .time, user: .grpc.request.claims.sub, app: .grpc.request.app}'

# Find failed authentication attempts
kubectl logs -n argocd deploy/argocd-server --since=1h | \
  jq 'select(.level == "error" and (.msg | contains("authentication")))'
```

---

## Supply Chain Security

### Image Signing and Verification

**Sign images with Cosign (Sigstore):**
```bash
# Sign an image
cosign sign --key cosign.key myregistry/myapp:v1.0.0

# Verify in admission controller (Kyverno)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-cosign
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "myregistry/myapp:*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

**With OPA Gatekeeper:**
```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: restrict-registries
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    repos:
      - "myregistry.example.com/"
      - "docker.io/library/"
```

### Attestation with SLSA

Generate and verify SLSA provenance:

```bash
# Generate SLSA provenance during CI build
slsa-verifier verify-image myregistry/myapp:v1.0.0 \
  --source-uri github.com/org/myapp \
  --source-tag v1.0.0

# Attach attestation
cosign attest --predicate provenance.json --key cosign.key myregistry/myapp:v1.0.0
```

**Kyverno policy to verify attestations:**
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-slsa-provenance
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-provenance
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences: ["myregistry/myapp:*"]
          attestations:
            - type: cosign
              predicateType: https://slsa.dev/provenance/v0.2
              conditions:
                - all:
                    - key: "{{ invocation.configSource.uri }}"
                      operator: Equals
                      value: "https://github.com/org/myapp"
```

### Manifest Verification with GPG

Argo CD can verify GPG signatures on Git commits:

```yaml
# argocd-cm
data:
  # Require GPG signature verification
  resource.customizations.useOpenLibs: "true"
```

```bash
# Import GPG public keys
argocd gpg add --from /path/to/public-key.asc

# List trusted keys
argocd gpg list

# Configure per-project signature requirements
argocd proj set my-project --signature-keys FINGERPRINT1,FINGERPRINT2
```

```yaml
# AppProject with signature verification
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
spec:
  signatureKeys:
    - keyID: "ABCDEF1234567890"
    - keyID: "1234567890ABCDEF"
```

When enabled, Argo CD will refuse to sync commits that are not signed by a trusted key.

### Hardening the Argo CD Installation

**1. Disable admin account:**
```yaml
# argocd-cm
data:
  admin.enabled: "false"
```

**2. Run components as non-root:**
```yaml
# Already default in recent versions, but verify:
securityContext:
  runAsNonRoot: true
  runAsUser: 999
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

**3. Use read-only filesystem for repo-server:**
```yaml
# Mount writable directories only where needed
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: helm-working-dir
    mountPath: /helm-working-dir
volumes:
  - name: tmp
    emptyDir: {}
  - name: helm-working-dir
    emptyDir: {}
```

**4. Limit cluster-admin access:**
```bash
# Use a restricted ClusterRole for Argo CD instead of cluster-admin
# Create specific roles per target namespace
```

**5. Enable TLS between components:**
```yaml
# argocd-cmd-params-cm
data:
  # Disable plaintext between components (use TLS)
  server.repo.server.plaintext: "false"
  controller.repo.server.plaintext: "false"
  # Note: TLS adds overhead. Use for high-security environments.
```

**6. Pod Security Standards:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

**7. Regular updates:**
```bash
# Stay current with Argo CD releases
# Security advisories: https://github.com/argoproj/argo-cd/security/advisories
# Check for CVEs:
argocd version
```
