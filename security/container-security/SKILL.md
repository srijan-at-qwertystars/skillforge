---
name: container-security
description:
  positive: >
    Use when user hardens container images, asks about image scanning (Trivy, Grype),
    rootless containers, seccomp profiles, AppArmor, container runtime security,
    SBOM generation, image signing (cosign/Sigstore), or Kubernetes pod security standards.
  negative: >
    Do NOT use for Dockerfile syntax (use dockerfile-best-practices skill),
    Kubernetes troubleshooting, or network security unrelated to containers.
---

# Container Security

## Image Security

### Minimal Base Images

Use the smallest viable base image. Fewer packages mean fewer vulnerabilities.

| Base Image | Packages | Attack Surface |
|------------|----------|----------------|
| `scratch` | 0 | Minimal — static binaries only |
| `distroless` | ~20 | No shell, no package manager |
| `alpine` | ~30 | musl-based, small footprint |
| `debian-slim` | ~80 | Reduced Debian |
| `ubuntu` | ~200+ | Large attack surface |

Prefer `scratch` for Go/Rust static binaries. Use `distroless` for Java, Python, Node.js. Fall back to `alpine` only when you need a package manager at build time.

### Vulnerability Scanning

Scan every image before push and on a recurring schedule. Block deployments with critical/high CVEs.

```bash
# Trivy — scan image for vulnerabilities
trivy image --severity HIGH,CRITICAL --exit-code 1 myapp:latest

# Trivy — scan for misconfigurations and secrets
trivy image --scanners vuln,misconfig,secret myapp:latest

# Trivy — generate SBOM
trivy image --format cyclonedx --output sbom.json myapp:latest
```

```bash
# Grype — scan image
grype myapp:latest --fail-on high

# Grype — scan from SBOM
syft myapp:latest -o cyclonedx-json > sbom.json
grype sbom:sbom.json
```

```bash
# Docker Scout — quick scan
docker scout cves myapp:latest

# Snyk Container
snyk container test myapp:latest --severity-threshold=high
```

Integrate scanning into CI. Fail the pipeline on critical findings.

## Supply Chain Security

### SBOM Generation

Generate an SBOM for every production image. Store it alongside the image in the registry.

```bash
# Syft — generate CycloneDX SBOM
syft myapp:latest -o cyclonedx-json > sbom.cdx.json

# Syft — generate SPDX SBOM
syft myapp:latest -o spdx-json > sbom.spdx.json

# Attach SBOM as attestation
cosign attest --predicate sbom.cdx.json \
  --type cyclonedx myapp@sha256:abc123
```

### Image Signing with Cosign/Sigstore

Sign every image after build. Verify before deploy.

```bash
# Keyless signing (OIDC — recommended for CI)
cosign sign myregistry.io/myapp@sha256:abc123

# Key-based signing
cosign generate-key-pair
cosign sign --key cosign.key myregistry.io/myapp@sha256:abc123

# Verify signature
cosign verify --certificate-identity=ci@myorg.com \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  myregistry.io/myapp@sha256:abc123
```

Always sign by digest, never by tag. Tags are mutable.

### Provenance Attestation

Attest build provenance using SLSA framework:

```bash
# Attach SLSA provenance
cosign attest --predicate provenance.json \
  --type slsaprovenance myapp@sha256:abc123
```

Use GitHub Actions reusable workflows or the SLSA generator to produce provenance automatically.

## Runtime Security

### Container Hardening Checklist

Apply all of these to every production container:

```yaml
# Kubernetes securityContext — hardened pod
apiVersion: v1
kind: Pod
metadata:
  name: hardened-app
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: myapp:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
        privileged: false
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
```

Key rules:
- Set `runAsNonRoot: true` — never run as UID 0.
- Set `allowPrivilegeEscalation: false` on every container.
- Set `readOnlyRootFilesystem: true` — mount writable `emptyDir` volumes for `/tmp` if needed.
- Drop `ALL` capabilities — add back only what is strictly required.
- Set `privileged: false` explicitly.
- Never mount the Docker socket (`/var/run/docker.sock`).

## Seccomp Profiles

### Default Profile

Use `RuntimeDefault` as the minimum. It blocks ~44 dangerous syscalls.

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

### Custom Seccomp Profile

Create a custom profile that only allows syscalls your app needs (default-deny all others). Deploy with `type: Localhost`:

```yaml
securityContext:
  seccompProfile:
    type: Localhost
    localhostProfile: profiles/myapp-seccomp.json
```

Use `strace` or tools like `oci-seccomp-bpf-hook` to audit which syscalls your app actually needs.

## AppArmor and SELinux

### AppArmor

Apply AppArmor profiles to restrict file access, network, and capabilities:

```yaml
metadata:
  annotations:
    container.apparmor.security.beta.kubernetes.io/app: localhost/myapp-apparmor
```

Write profiles that allow only what your app needs (read app files, write to `/tmp`, deny sensitive paths like `/etc/shadow`, `/proc/*/mem`). Load profiles on nodes with `apparmor_parser`.

### SELinux

On SELinux-enforcing hosts, assign container labels:

```yaml
securityContext:
  seLinuxOptions:
    level: "s0:c123,c456"
    type: "container_t"
```

Use `container_t` for standard containers. Avoid `spc_t` (super-privileged).

## Rootless Containers

Rootless mode maps container root (UID 0) to an unprivileged host UID via user namespaces. A container escape yields no host privileges.

### Docker Rootless Mode

```bash
# Install rootless Docker
dockerd-rootless-setuptool.sh install

# Verify
docker context use rootless
docker info | grep -i rootless
```

### Podman Rootless (Default)

Podman runs rootless by default — no daemon, no root:

```bash
# Run container as non-root user
podman run --rm -it --userns=auto myapp:latest

# Verify UID mapping
podman unshare cat /proc/self/uid_map
```

### User Namespace Remapping

Add to `/etc/docker/daemon.json` and restart Docker:

```json
{
  "userns-remap": "default"
}
```

Container UID 0 maps to a high unprivileged host UID.

## Kubernetes Pod Security Standards

### Three Levels

| Level | Purpose | Use Case |
|-------|---------|----------|
| **Privileged** | Unrestricted | System/infra components only |
| **Baseline** | Minimal restrictions | Legacy apps, transitional |
| **Restricted** | Full hardening | All production workloads |

### Enforce via Namespace Labels

```bash
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/enforce-version=v1.31
```

### Restricted Profile Requirements

All of these must be true for a pod to pass the restricted profile:
- `runAsNonRoot: true`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault` or `Localhost`
- No `hostNetwork`, `hostPID`, `hostIPC`
- No `hostPath` volumes
- No `privileged: true`

### Migration Strategy

Label namespaces with `audit` and `warn` modes first. Review violations. Fix workloads. Then switch to `enforce`.

## Secret Management

Never bake secrets into images. Never pass secrets via environment variables in Dockerfiles.

### Kubernetes Secrets (Mounted)

```yaml
volumes:
  - name: db-creds
    secret:
      secretName: db-credentials
      defaultMode: 0400
containers:
  - name: app
    volumeMounts:
      - name: db-creds
        mountPath: /run/secrets/db
        readOnly: true
```

### External Secret Managers

Use External Secrets Operator to sync from Vault, AWS Secrets Manager, GCP Secret Manager, or Azure Key Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: db-credentials
  data:
    - secretKey: password
      remoteRef:
        key: secret/data/db
        property: password
```

### Rules

- Mount secrets as files, not env vars (env vars leak in logs/debug).
- Set `defaultMode: 0400` — read-only by owner.
- Rotate secrets regularly. Use short-lived credentials where possible.
- Never commit secrets to version control.

## Network Security

### Kubernetes Network Policies

Deny all traffic by default, then allow only what is needed:
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Allow specific traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-db
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: myapp
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
          protocol: TCP
```

### Service Mesh mTLS

Enforce mutual TLS between pods with Istio or Linkerd:

```yaml
# Istio PeerAuthentication — strict mTLS
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: production
spec:
  mtls:
    mode: STRICT
```

## Registry Security

### Private Registry Practices

- Use private registries. Block pulls from public registries in production.
- Enable content trust and image signing verification.
- Pin images by digest. Tags are mutable.
- Scan images on push and on a recurring schedule.

### Admission Controllers

Use admission controllers to enforce image policies at deploy time:

```yaml
# Kyverno — require signed images
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "myregistry.io/*"
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/myorg/*"
```

```yaml
# OPA Gatekeeper — deny images from untrusted registries
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: allowed-repos
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
  parameters:
    repos:
      - "myregistry.io/"
      - "gcr.io/distroless/"
```

## CI/CD Security Pipeline

Follow this order: **Build → Scan → Generate SBOM → Sign → Push → Verify → Deploy**

### GitHub Actions Example

```yaml
name: Secure Container Build
on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write
  id-token: write  # Required for keyless signing

jobs:
  build-scan-sign:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build image
        run: docker build -t myregistry.io/myapp:${{ github.sha }} .

      - name: Scan with Trivy
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: myregistry.io/myapp:${{ github.sha }}
          exit-code: 1
          severity: HIGH,CRITICAL

      - name: Generate SBOM
        run: syft myregistry.io/myapp:${{ github.sha }} -o cyclonedx-json > sbom.cdx.json

      - name: Push image
        run: docker push myregistry.io/myapp:${{ github.sha }}

      - name: Sign image (keyless)
        run: |
          cosign sign myregistry.io/myapp@$(docker inspect --format='{{index .RepoDigests 0}}' myregistry.io/myapp:${{ github.sha }} | cut -d@ -f2)

      - name: Attach SBOM attestation
        run: cosign attest --predicate sbom.cdx.json --type cyclonedx myregistry.io/myapp@sha256:...
```

### Pipeline Rules

- Fail builds on critical/high vulnerabilities.
- Generate SBOM and sign every image by digest after push.
- Verify signatures via admission controller before deploy.
- Re-scan deployed images weekly for newly disclosed CVEs.
