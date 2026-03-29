---
name: sigstore
description: |
  Container image signing and verification with Sigstore. Use for supply chain security.
  NOT for simple TLS/mTLS without image signing needs.
tested: 2026-03-29
---

# Sigstore: Supply Chain Security

Open-source security infrastructure for signing, verifying, and protecting software artifacts.

## Quick Start

```bash
# Install cosign
curl -sL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o cosign
chmod +x cosign && sudo mv cosign /usr/local/bin/

# Generate keypair (for dev/testing)
cosign generate-key-pair
# Output: cosign.key, cosign.pub

# Sign an image with key
cosign sign --key cosign.key registry.io/image:tag

# Verify with key
cosign verify --key cosign.pub registry.io/image:tag
```

## Keyless Signing (Recommended)

Uses OIDC identity (GitHub, Google, Microsoft) - no key management.

```bash
# Sign with OIDC (opens browser for auth)
cosign sign registry.io/image:tag
# Output:
# Generating ephemeral keys...
# Retrieving signed certificate from Fulcio...
# Successfully signed with Fulcio certificate

# Verify using transparency log
cosign verify registry.io/image:tag \
  --certificate-identity=user@example.com \
  --certificate-oidc-issuer=https://accounts.google.com
# Output:
# Verification for registry.io/image:tag --
# The following checks were performed:
#   - The cosign claims were validated
#   - The signatures were verified against the specified public key
#   - Any certificates were verified against the Fulcio roots
#   - The signature was present in the transparency log
```

## Cosign: Container Signing

### Sign Images

```bash
# Sign with private key
cosign sign --key cosign.key $IMAGE

# Sign with KMS (AWS, GCP, Azure, HashiCorp)
cosign sign --key awskms:///arn:aws:kms:us-east-1:123:key/abc $IMAGE
cosign sign --key gcpkms://projects/proj/locations/global/keyRings/ring/cryptoKeys/key $IMAGE
cosign sign --key azurekms://vault.vault.azure.net/keys/key $IMAGE
cosign sign --key hashivault://key $IMAGE

# Sign with existing certificate
cosign sign --cert cert.pem --key key.pem $IMAGE

# Sign with annotations
cosign sign --key cosign.key \
  -a commit=$(git rev-parse HEAD) \
  -a repo=github.com/org/repo \
  $IMAGE
```

### Verify Images

```bash
# Basic verification
cosign verify --key cosign.pub $IMAGE

# Verify with specific identity (keyless)
cosign verify $IMAGE \
  --certificate-identity=alice@example.com \
  --certificate-oidc-issuer=https://github.com/login/oauth

# Verify multiple identities
cosign verify $IMAGE \
  --certificate-identity-regexp=".*@example.com" \
  --certificate-oidc-issuer=https://accounts.google.com

# Verify with policy (require specific annotations)
cosign verify --key cosign.pub $IMAGE \
  --annotations commit=abc123 \
  --annotations repo=github.com/org/repo
```

### Sign/Verify SBOMs and Attestations

```bash
# Sign SBOM
cosign attest --predicate sbom.spdx.json \
  --type spdxjson \
  --key cosign.key $IMAGE

# Verify SBOM attestation
cosign verify-attestation --key cosign.pub $IMAGE \
  --type spdxjson \
  --output-file verified-sbom.json

# Sign SLSA provenance
cosign attest --predicate provenance.json \
  --type slsaprovenance \
  --key cosign.key $IMAGE

# Verify SLSA provenance
cosign verify-attestation --key cosign.pub $IMAGE \
  --type slsaprovenance
```

## Fulcio: Certificate Authority

Free root CA for code signing certificates. Issues short-lived certs (~10 min) bound to OIDC identity.

### Custom Fulcio Instance

```bash
# Run private Fulcio (for air-gapped environments)
docker run -p 5555:5555 \
  -v $(pwd)/fulcio-config.yaml:/etc/fulcio/config.yaml \
  gcr.io/projectsigstore/fulcio:latest serve \
  --config-path=/etc/fulcio/config.yaml \
  --ca=pkcs11ca

# Sign with custom Fulcio
COSIGN_FULCIO_URL=http://localhost:5555 \
  cosign sign --fulcio-url=http://localhost:5555 $IMAGE
```

### Fulcio Config (fulcio-config.yaml)

```yaml
oidc-issuers:
  https://accounts.google.com:
    issuer-url: https://accounts.google.com
    client-id: <client-id>
    type: email
  https://token.actions.githubusercontent.com:
    issuer-url: https://token.actions.githubusercontent.com
    client-id: sigstore
    type: uri
```

## Rekor: Transparency Log

Immutable, append-only transparency log for signed artifacts.

### Query Rekor

```bash
# Get entry by log index
rekor-cli get --log-index 1234567 --format json

# Search by artifact digest
rekor-cli search --sha sha256:abc123...
# Output:
# Found matching entries:
# [1234567 1234568]

# Get entry by UUID
rekor-cli get --uuid 3628bed... --format json | jq .

# Verify inclusion proof
rekor-cli verify --uuid 3628bed...
```

### Custom Rekor Instance

```bash
# Run private Rekor
docker run -p 3000:3000 \
  gcr.io/projectsigstore/rekor-server:latest serve

# Sign with custom Rekor
COSIGN_REKOR_URL=http://localhost:3000 \
  cosign sign --rekor-url=http://localhost:3000 $IMAGE
```

### Rekor CLI Operations

```bash
# Upload artifact signature manually
rekor-cli upload --artifact artifact.tar.gz \
  --signature artifact.sig \
  --pki-format=x509 \
  --public-key=cosign.pub

# Get entry as inclusion promise
rekor-cli get --log-index 1234567 --format json | jq '.verification.inclusionProof'
```

## Policy Enforcement

### Kubernetes Admission Controller

```yaml
# policy-controller deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: policy-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: policy-webhook
  template:
    spec:
      containers:
      - name: webhook
        image: ghcr.io/sigstore/policy-controller/policy-controller:latest
        args:
        - --policy-resync-period=10m
        - --tls-cert=/etc/webhook/certs/tls.crt
        - --tls-key=/etc/webhook/certs/tls.key
---
# ClusterImagePolicy - require signed images
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-sigstore-signed
spec:
  images:
  - glob: "ghcr.io/org/**"
  authorities:
  - keyless:
      url: https://fulcio.sigstore.dev
      identities:
      - issuer: https://token.actions.githubusercontent.com
        subject: https://github.com/org/repo/.github/workflows/*.yaml@refs/heads/main
  - static:
      action: pass
---
# Require specific key
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-specific-key
spec:
  images:
  - glob: "registry.io/production/**"
  authorities:
  - key:
      data: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
        -----END PUBLIC KEY-----
  - key:
      secretRef:
        name: signing-pubkey
        namespace: cosign-system
```

## OCI Registry Integration

### Supported Registries

```bash
# Docker Hub
cosign sign docker.io/user/image:tag

# GHCR (GitHub Container Registry)
cosign sign ghcr.io/org/image:tag

# GCR (Google Container Registry)
cosign sign gcr.io/project/image:tag

# ECR (Amazon Elastic Container Registry)
cosign sign 123456789.dkr.ecr.us-east-1.amazonaws.com/image:tag

# ACR (Azure Container Registry)
cosign sign myregistry.azurecr.io/image:tag

# Harbor, Artifactory, Quay (with cosign support)
cosign sign harbor.example.com/project/image:tag
```

### Registry Authentication

```bash
# Use existing docker credentials
cosign sign --k8s-keychain $IMAGE

# Use specific auth file
cosign sign --authfile /path/to/auth.json $IMAGE

# Use registry token directly
cosign sign --registry-token $(gcloud auth print-access-token) gcr.io/.../image
```

### Attach/Detach Signatures

```bash
# Attach signature to existing image
cosign attach signature --signature sig.sig --payload payload.json $IMAGE

# Download signature
cosign download signature $IMAGE > sig.sig

# Download attestation
cosign download attestation $IMAGE > attestation.json

# Copy signature between registries
cosign copy --sig-only $SOURCE_IMAGE $DEST_IMAGE
```

## CI/CD Integration

### GitHub Actions

```yaml
# .github/workflows/sign.yml
name: Sign Container Image
on:
  push:
    branches: [main]

jobs:
  sign:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write  # Required for OIDC
      packages: write
    steps:
    - uses: actions/checkout@v4
    
    - name: Build image
      run: docker build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .
    
    - name: Install cosign
      uses: sigstore/cosign-installer@v3
    
    - name: Sign image with keyless
      run: |
        cosign sign --yes \
          ghcr.io/${{ github.repository }}:${{ github.sha }}
      env:
        COSIGN_EXPERIMENTAL: 1
    
    - name: Sign with SBOM attestation
      run: |
        # Generate SBOM
        syft ghcr.io/${{ github.repository }}:${{ github.sha }} \
          -o spdx-json=sbom.spdx.json
        
        # Attest SBOM
        cosign attest --predicate sbom.spdx.json \
          --type spdxjson \
          --yes \
          ghcr.io/${{ github.repository }}:${{ github.sha }}
```

### GitLab CI

```yaml
# .gitlab-ci.yml
sign-image:
  stage: deploy
  image: bitnami/cosign:latest
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  script:
    - cosign sign $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  only:
    - main
```

### Tekton Chains

```yaml
# Tekton Chains config for automatic signing
apiVersion: v1
kind: ConfigMap
metadata:
  name: chains-config
  namespace: tekton-chains
data:
  artifacts.taskrun.format: "slsa/v1"
  artifacts.taskrun.storage: "oci"
  artifacts.oci.format: "simplesigning"
  artifacts.oci.storage: "oci"
  transparency.enabled: "true"
```

## Advanced Workflows

### Air-Gapped/Private Deployment

```bash
# 1. Deploy private Fulcio + Rekor
docker-compose up -d fulcio rekor

# 2. Configure cosign to use private instances
export COSIGN_FULCIO_URL=http://fulcio.internal:5555
export COSIGN_REKOR_URL=http://rekor.internal:3000
export COSIGN_CT_LOG_URL=http://ctlog.internal:6962

# 3. Trust private CA
cosign initialize --mirror http://tuf.internal --root ./root.json

# 4. Sign with private infrastructure
cosign sign --fulcio-url=$COSIGN_FULCIO_URL \
  --rekor-url=$COSIGN_REKOR_URL \
  registry.internal/image:tag
```

### Key Management Best Practices

```bash
# Use KMS - never handle raw keys locally
cosign sign --key awskms:///arn:aws:kms:region:account:key/id $IMAGE

# Use Kubernetes secret (for CI/CD)
cosign generate-key-pair k8s://namespace/secret-name
# Creates secret with 'cosign.key' and 'cosign.pub'
cosign sign --key k8s://namespace/secret-name $IMAGE

# Use HashiCorp Vault
cosign sign --key hashivault://transit/key-name $IMAGE

# Use Azure Key Vault
cosign sign --key azurekms://vault.vault.azure.net/keys/key-name $IMAGE
```

### Verify Multiple Policies

```bash
#!/bin/bash
IMAGE=$1
FAILED=0

# Check CI signature
cosign verify $IMAGE \
  --certificate-identity-regexp=".*@github-actions" \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com || FAILED=1

# Check SBOM attestation
cosign verify-attestation $IMAGE --type spdxjson || FAILED=1

# Check SLSA provenance  
cosign verify-attestation $IMAGE --type slsaprovenance || FAILED=1

[ $FAILED -eq 0 ] && echo "All checks passed" || { echo "Verification failed"; exit 1; }
```

## Troubleshooting

```bash
# Debug signature verification
cosign verify --verbose $IMAGE

# Check Rekor entry exists
rekor-cli search --sha $(crane digest $IMAGE)

# Verify certificate chain
cosign verify --cert-chain chain.pem $IMAGE

# Skip Rekor (offline/air-gapped)
cosign verify --insecure-ignore-tlog $IMAGE

# Skip SCT verification (for private Fulcio)
cosign verify --insecure-ignore-sct $IMAGE

# Check TUF root status
cosign initialize --mirror https://sigstore-tuf-root.storage.googleapis.com
```

## Reference

| Component | Purpose | Default URL |
|-----------|---------|-------------|
| Cosign | CLI for signing/verifying | - |
| Fulcio | OIDC-based CA | https://fulcio.sigstore.dev |
| Rekor | Transparency log | https://rekor.sigstore.dev |
| TUF | Root of trust distribution | https://sigstore-tuf-root.storage.googleapis.com |

| Flag | Description |
|------|-------------|
| `--key` | Path to private key or KMS reference |
| `--cert` | Path to signing certificate |
| `--certificate-identity` | Expected signer identity |
| `--certificate-oidc-issuer` | Expected OIDC issuer |
| `--rekor-url` | Custom Rekor instance |
| `--fulcio-url` | Custom Fulcio instance |
| `--insecure-ignore-tlog` | Skip transparency log verification |
