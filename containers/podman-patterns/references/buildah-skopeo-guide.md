# Buildah & Skopeo Comprehensive Guide

## Table of Contents

- [Buildah Advanced Usage](#buildah-advanced-usage)
  - [Buildah Fundamentals](#buildah-fundamentals)
  - [Scripted (Shell-Based) Builds](#scripted-shell-based-builds)
  - [Multi-Stage Builds](#multi-stage-builds)
  - [Building from Scratch](#building-from-scratch)
  - [Mount, Copy, and Run Operations](#mount-copy-and-run-operations)
  - [Build Arguments and Configuration](#build-arguments-and-configuration)
  - [Layer and Cache Management](#layer-and-cache-management)
  - [Multi-Arch Builds with Buildah](#multi-arch-builds-with-buildah)
- [Skopeo Operations](#skopeo-operations)
  - [Skopeo Fundamentals](#skopeo-fundamentals)
  - [Inspecting Images](#inspecting-images)
  - [Copying Images Between Registries](#copying-images-between-registries)
  - [Syncing Repositories](#syncing-repositories)
  - [Authentication and Login](#authentication-and-login)
  - [Deleting Remote Images](#deleting-remote-images)
  - [Working with Image Formats](#working-with-image-formats)
- [Image Signing](#image-signing)
  - [Sigstore (Cosign) Signing](#sigstore-cosign-signing)
  - [GPG Signing](#gpg-signing)
  - [Signature Verification Policy](#signature-verification-policy)
  - [Sigstore with Buildah Push](#sigstore-with-buildah-push)
- [Registry Mirroring](#registry-mirroring)
  - [Configuring Registry Mirrors](#configuring-registry-mirrors)
  - [Setting Up a Local Mirror](#setting-up-a-local-mirror)
  - [Air-Gapped Environment Sync](#air-gapped-environment-sync)
  - [Registry Authentication Files](#registry-authentication-files)
- [CI/CD Integration with Buildah](#cicd-integration-with-buildah)
  - [GitHub Actions](#github-actions)
  - [GitLab CI](#gitlab-ci)
  - [Jenkins Pipeline](#jenkins-pipeline)
  - [Tekton Tasks](#tekton-tasks)
  - [Security Best Practices for CI/CD](#security-best-practices-for-cicd)

---

## Buildah Advanced Usage

### Buildah Fundamentals

Buildah builds OCI/Docker images without requiring a daemon. It can use Containerfiles
(Dockerfiles) or shell scripts for fine-grained control.

```bash
# Build from Containerfile (default)
buildah build -t myapp:latest .

# Build with specific Containerfile
buildah build -t myapp:latest -f Containerfile.prod .

# Build with build args
buildah build --build-arg VERSION=1.2.3 -t myapp:latest .

# Build with squash (single layer)
buildah build --squash -t myapp:latest .

# Build without cache
buildah build --no-cache -t myapp:latest .

# Build for specific platform
buildah build --platform linux/arm64 -t myapp:arm64 .

# List working containers
buildah containers

# List built images
buildah images
```

### Scripted (Shell-Based) Builds

Buildah's unique strength: build images with shell commands for full programmatic control.

```bash
#!/bin/bash
set -euo pipefail

# Start from a base image
ctr=$(buildah from docker.io/library/python:3.12-slim)

# Get the mount point for direct filesystem access
mnt=$(buildah mount $ctr)

# Run commands inside the container
buildah run $ctr -- pip install --no-cache-dir flask gunicorn

# Copy files from host
buildah copy $ctr ./app /opt/app
buildah copy $ctr ./requirements.txt /opt/app/

# Set configuration
buildah config \
  --workingdir /opt/app \
  --port 8080 \
  --env APP_ENV=production \
  --env PYTHONUNBUFFERED=1 \
  --entrypoint '["gunicorn"]' \
  --cmd "app:app -b 0.0.0.0:8080 -w 4" \
  --author "DevOps Team" \
  --label version=1.0 \
  --label maintainer=devops@example.com \
  --user 1000:1000 \
  --stop-signal SIGTERM \
  $ctr

# Commit the container to an image
buildah commit --squash $ctr myapp:latest

# Cleanup
buildah unmount $ctr
buildah rm $ctr
```

### Multi-Stage Builds

```bash
#!/bin/bash
set -euo pipefail

# Stage 1: Build
builder=$(buildah from docker.io/library/golang:1.22-alpine)
buildah run $builder -- apk add --no-cache git ca-certificates
buildah copy $builder . /src
buildah config --workingdir /src $builder
buildah run $builder -- go build -ldflags="-s -w" -o /app ./cmd/server

# Stage 2: Runtime (minimal image)
runtime=$(buildah from docker.io/library/alpine:3.20)
buildah run $runtime -- apk add --no-cache ca-certificates tzdata

# Copy binary from builder stage
builder_mnt=$(buildah mount $builder)
buildah copy $runtime "$builder_mnt/app" /usr/local/bin/app
buildah unmount $builder

# Configure runtime
buildah config \
  --entrypoint '["/usr/local/bin/app"]' \
  --port 8080 \
  --user 65534:65534 \
  $runtime

# Commit
buildah commit --squash $runtime myapp:latest

# Cleanup
buildah rm $builder $runtime
```

### Building from Scratch

Build minimal images with only what you need:

```bash
#!/bin/bash
set -euo pipefail

# Start from scratch (empty filesystem)
ctr=$(buildah from scratch)
mnt=$(buildah mount $ctr)

# For a static Go binary
# Copy just the binary (no OS, no shell, no libc)
cp ./myapp-static "$mnt/app"

# Add CA certificates for HTTPS
mkdir -p "$mnt/etc/ssl/certs"
cp /etc/ssl/certs/ca-certificates.crt "$mnt/etc/ssl/certs/"

# Add timezone data
mkdir -p "$mnt/usr/share/zoneinfo"
cp -r /usr/share/zoneinfo/* "$mnt/usr/share/zoneinfo/"

# Add /tmp directory
mkdir -p "$mnt/tmp"

# Create non-root user (manual /etc/passwd)
echo 'appuser:x:65534:65534::/nonexistent:/bin/false' > "$mnt/etc/passwd"
echo 'appgroup:x:65534:' > "$mnt/etc/group"

buildah config \
  --entrypoint '["/app"]' \
  --port 8080 \
  --user 65534:65534 \
  $ctr

buildah unmount $ctr
buildah commit $ctr myapp:scratch

buildah rm $ctr
```

### Mount, Copy, and Run Operations

```bash
ctr=$(buildah from alpine:3.20)

# --- MOUNT: Direct filesystem access ---
mnt=$(buildah mount $ctr)

# Read/write directly to the container filesystem
echo "config=value" > "$mnt/etc/app.conf"
cp -r ./static-files "$mnt/var/www/"

# Install packages via host tools (no need to run inside container)
dnf install --installroot "$mnt" --releasever 40 -y python3

buildah unmount $ctr

# --- COPY: Transfer files with metadata ---
# Basic copy
buildah copy $ctr ./app /opt/app

# Copy with ownership
buildah copy --chown 1000:1000 $ctr ./config /etc/myapp/

# Copy with chmod
buildah copy --chmod 0755 $ctr ./entrypoint.sh /

# Copy from URL
buildah copy $ctr https://example.com/file.tar.gz /tmp/

# Copy preserving timestamps
buildah copy $ctr ./data /data

# --- RUN: Execute commands in container ---
# Simple command
buildah run $ctr -- apk add --no-cache curl

# Multi-command with shell
buildah run $ctr -- sh -c 'apk update && apk add python3 && rm -rf /var/cache/apk/*'

# Run with environment variables
buildah run --env HTTP_PROXY=http://proxy:8080 $ctr -- pip install flask

# Run with volume mount (from host)
buildah run -v ./scripts:/scripts:Z $ctr -- sh /scripts/setup.sh

# Run with network isolation (no network access)
buildah run --network none $ctr -- pip install --no-index --find-links=/wheels flask

# Run with custom user
buildah run --user 1000:1000 $ctr -- whoami
```

### Build Arguments and Configuration

```bash
ctr=$(buildah from alpine:3.20)

# Set all configuration options
buildah config \
  --author "Jane Doe <jane@example.com>" \
  --created-by "buildah build script" \
  --workingdir /app \
  --env APP_ENV=production \
  --env LOG_LEVEL=info \
  --port 8080 \
  --port 8443 \
  --volume /data \
  --entrypoint '["/entrypoint.sh"]' \
  --cmd "serve" \
  --user 1000:1000 \
  --stop-signal SIGTERM \
  --label version=1.0 \
  --label org.opencontainers.image.source=https://github.com/org/repo \
  --label org.opencontainers.image.description="My Application" \
  --annotation org.opencontainers.image.authors="team@example.com" \
  --healthcheck "CMD curl -f http://localhost:8080/health" \
  --healthcheck-interval 30s \
  --healthcheck-timeout 5s \
  --healthcheck-retries 3 \
  --healthcheck-start-period 10s \
  --shell /bin/sh \
  $ctr

# Inspect configuration
buildah inspect $ctr
buildah inspect --format '{{.OCIv1.Config.Cmd}}' $ctr
```

### Layer and Cache Management

```bash
# Build with layer caching
buildah build --layers -t myapp:latest .

# Build without cache
buildah build --no-cache -t myapp:latest .

# Squash all layers into one
buildah build --squash -t myapp:latest .

# Commit with squash
buildah commit --squash $ctr myapp:latest

# Remove intermediate layers
buildah commit --rm $ctr myapp:latest

# Cache mount (build cache across builds)
# In Containerfile:
# RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt

# Inspect layer history
buildah inspect --format '{{range .OCIv1.History}}{{.CreatedBy}}{{"\n"}}{{end}}' myapp:latest
```

### Multi-Arch Builds with Buildah

```bash
#!/bin/bash
set -euo pipefail

IMAGE="quay.io/user/myapp"
TAG="latest"

# Create manifest list
buildah manifest create "${IMAGE}:${TAG}"

# Build for each platform
for PLATFORM in linux/amd64 linux/arm64 linux/s390x linux/ppc64le; do
  echo "Building for $PLATFORM..."
  buildah build \
    --platform "$PLATFORM" \
    --manifest "${IMAGE}:${TAG}" \
    -f Containerfile .
done

# Inspect manifest
buildah manifest inspect "${IMAGE}:${TAG}"

# Push manifest list with all architectures
buildah manifest push --all \
  "${IMAGE}:${TAG}" \
  "docker://${IMAGE}:${TAG}"

# Cleanup
buildah manifest rm "${IMAGE}:${TAG}"
```

---

## Skopeo Operations

### Skopeo Fundamentals

Skopeo performs operations on container images and registries without pulling layers locally.

Supported transports:
| Transport | Example | Description |
|-----------|---------|-------------|
| `docker://` | `docker://registry.io/image:tag` | Remote registry |
| `containers-storage:` | `containers-storage:localhost/myapp:latest` | Local Podman/Buildah storage |
| `dir:` | `dir:/path/to/dir` | Local directory (OCI layout) |
| `oci:` | `oci:/path:tag` | OCI image layout |
| `docker-archive:` | `docker-archive:file.tar` | Docker tar archive |
| `oci-archive:` | `oci-archive:file.tar` | OCI tar archive |
| `docker-daemon:` | `docker-daemon:image:tag` | Docker daemon storage |

### Inspecting Images

```bash
# Inspect remote image (no download)
skopeo inspect docker://docker.io/library/nginx:alpine

# Get raw JSON manifest
skopeo inspect --raw docker://docker.io/library/nginx:alpine

# Get specific architecture manifest
skopeo inspect --raw docker://docker.io/library/nginx:alpine \
  | jq '.manifests[] | select(.platform.architecture=="arm64")'

# Inspect config only
skopeo inspect --config docker://docker.io/library/nginx:alpine

# Get image digest
skopeo inspect --format '{{.Digest}}' docker://nginx:alpine

# Get image labels
skopeo inspect --format '{{.Labels}}' docker://myregistry/myapp:latest

# Inspect local image
skopeo inspect containers-storage:localhost/myapp:latest

# List tags for a repository
skopeo list-tags docker://docker.io/library/nginx
```

### Copying Images Between Registries

```bash
# Copy single image
skopeo copy \
  docker://docker.io/library/nginx:alpine \
  docker://registry.internal:5000/library/nginx:alpine

# Copy all architectures (manifest list)
skopeo copy --all \
  docker://docker.io/library/nginx:alpine \
  docker://registry.internal:5000/library/nginx:alpine

# Copy with different credentials
skopeo copy \
  --src-creds user:pass \
  --dest-creds admin:secret \
  docker://source.io/image:tag \
  docker://dest.io/image:tag

# Copy using auth files
skopeo copy \
  --src-authfile /path/to/source-auth.json \
  --dest-authfile /path/to/dest-auth.json \
  docker://source.io/image:tag \
  docker://dest.io/image:tag

# Copy to local directory (OCI layout)
skopeo copy docker://nginx:alpine dir:./nginx-local

# Copy to OCI archive
skopeo copy docker://nginx:alpine oci-archive:nginx.tar:latest

# Copy to Docker archive (for docker load)
skopeo copy docker://nginx:alpine docker-archive:nginx-docker.tar

# Copy from local storage to registry
skopeo copy \
  containers-storage:localhost/myapp:latest \
  docker://registry.internal:5000/myapp:latest

# Copy with encryption
skopeo copy --encryption-key jwe:pubkey.pem \
  docker://nginx:alpine \
  docker://registry.internal:5000/nginx:alpine-encrypted

# Copy preserving digests
skopeo copy --preserve-digests \
  docker://source.io/image@sha256:abc123 \
  docker://dest.io/image@sha256:abc123
```

### Syncing Repositories

```bash
# Sync from registry to local directory
skopeo sync --src docker --dest dir \
  docker.io/library/nginx \
  /backups/images/

# Sync from directory to registry
skopeo sync --src dir --dest docker \
  /backups/images/ \
  registry.internal:5000

# Sync specific tags using YAML config
cat > sync-config.yaml << 'EOF'
docker.io:
  images:
    nginx:
      - "alpine"
      - "1.27"
      - "latest"
    redis:
      - "7-alpine"
      - "latest"
  images-by-tag-regex:
    python:
      - "^3\\.12.*slim$"
quay.io:
  images:
    prometheus/prometheus:
      - "latest"
      - "v2.53.0"
EOF

skopeo sync --src yaml --dest docker \
  sync-config.yaml \
  registry.internal:5000

# Sync with TLS options
skopeo sync --src docker --dest docker \
  --dest-tls-verify=false \
  docker.io/library/nginx \
  registry.internal:5000

# Sync all tags of an image
skopeo sync --src docker --dest dir \
  --all \
  docker.io/library/alpine \
  /backups/alpine/
```

### Authentication and Login

```bash
# Login to registry
skopeo login docker.io
skopeo login -u username -p password registry.internal:5000
skopeo login --authfile /path/to/auth.json quay.io

# Login with token
echo "$TOKEN" | skopeo login --password-stdin registry.internal:5000

# Logout
skopeo logout docker.io
skopeo logout --all

# Auth file location (shared with Podman/Buildah)
# Default: ${XDG_RUNTIME_DIR}/containers/auth.json
# Or: ~/.docker/config.json (Docker compatibility)

# Use specific auth file
skopeo inspect --authfile /path/to/auth.json docker://private.io/image:tag

# Generate auth file
cat > auth.json << 'EOF'
{
  "auths": {
    "registry.internal:5000": {
      "auth": "dXNlcjpwYXNz"
    },
    "quay.io": {
      "auth": "dXNlcjpwYXNz"
    }
  }
}
EOF
```

### Deleting Remote Images

```bash
# Delete a tag from registry
skopeo delete docker://registry.internal:5000/myapp:old-tag

# Delete by digest
skopeo delete docker://registry.internal:5000/myapp@sha256:abc123

# Note: Registry must have deletion enabled
# For Docker registry: REGISTRY_STORAGE_DELETE_ENABLED=true
# For Harbor/Quay: enabled by default

# After deletion, run garbage collection on registry
# Docker registry: registry garbage-collect /etc/docker/registry/config.yml
```

### Working with Image Formats

```bash
# Convert between formats
# Docker → OCI
skopeo copy docker://nginx:alpine oci:./nginx-oci:latest

# OCI → Docker archive
skopeo copy oci:./nginx-oci:latest docker-archive:nginx.tar

# Docker archive → local storage
skopeo copy docker-archive:nginx.tar containers-storage:nginx:imported

# Directory → registry
skopeo copy dir:./image-dir docker://registry.internal:5000/myapp:latest

# Inspect format differences
skopeo inspect --raw oci:./nginx-oci:latest | jq .mediaType
# application/vnd.oci.image.manifest.v1+json

skopeo inspect --raw docker://nginx:alpine | jq .mediaType
# application/vnd.docker.distribution.manifest.v2+json
```

---

## Image Signing

### Sigstore (Cosign) Signing

```bash
# Install cosign
# https://docs.sigstore.dev/cosign/installation/

# Generate a key pair
cosign generate-key-pair

# Sign an image
cosign sign --key cosign.key registry.io/myapp:latest

# Keyless signing (OIDC identity)
cosign sign registry.io/myapp:latest
# Opens browser for OIDC auth (GitHub, Google, Microsoft)

# Verify signature
cosign verify --key cosign.pub registry.io/myapp:latest

# Keyless verification
cosign verify \
  --certificate-identity user@example.com \
  --certificate-oidc-issuer https://accounts.google.com \
  registry.io/myapp:latest

# Attach SBOM
cosign attach sbom --sbom sbom.spdx registry.io/myapp:latest

# Sign with annotations
cosign sign --key cosign.key \
  -a commit=$(git rev-parse HEAD) \
  -a pipeline=ci \
  registry.io/myapp:latest
```

### GPG Signing

```bash
# Configure signing in registries.d
sudo mkdir -p /etc/containers/registries.d/
cat | sudo tee /etc/containers/registries.d/default.yaml << 'EOF'
default-docker:
  sigstore: file:///var/lib/containers/sigstore/
  sigstore-staging: file:///var/lib/containers/sigstore/
docker:
  registry.internal:5000:
    sigstore: https://sigstore.internal/signatures/
    sigstore-staging: file:///var/lib/containers/sigstore/
EOF

# Sign image with GPG
podman push --sign-by user@example.com \
  localhost/myapp:latest \
  docker://registry.internal:5000/myapp:latest

# Sign with Buildah
buildah push --sign-by user@example.com \
  localhost/myapp:latest \
  docker://registry.internal:5000/myapp:latest
```

### Signature Verification Policy

Configure signature requirements in `/etc/containers/policy.json`:

```json
{
  "default": [
    { "type": "reject" }
  ],
  "transports": {
    "docker": {
      "registry.internal:5000": [
        {
          "type": "signedBy",
          "keyType": "GPGKeys",
          "keyPath": "/etc/pki/rpm-gpg/RPM-GPG-KEY-myorg"
        }
      ],
      "docker.io": [
        { "type": "insecureAcceptAnything" }
      ]
    },
    "atomic": {
      "": [
        { "type": "insecureAcceptAnything" }
      ]
    }
  }
}
```

### Sigstore with Buildah Push

```bash
# Sign during push using sigstore
buildah push \
  --sign-by-sigstore-private-key cosign.key \
  myapp:latest \
  docker://registry.io/myapp:latest

# Verify on pull
podman pull \
  --decryption-key cosign.pub \
  registry.io/myapp:latest
```

---

## Registry Mirroring

### Configuring Registry Mirrors

In `/etc/containers/registries.conf`:

```toml
# Mirror Docker Hub
[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "mirror.gcr.io"

[[registry.mirror]]
location = "registry.internal:5000/docker.io"

# Mirror quay.io
[[registry]]
prefix = "quay.io"
location = "quay.io"

[[registry.mirror]]
location = "registry.internal:5000/quay.io"

# Mirror with insecure connection
[[registry]]
prefix = "docker.io"
location = "docker.io"

[[registry.mirror]]
location = "registry.internal:5000"
insecure = true
```

### Setting Up a Local Mirror

```bash
# Run a registry mirror with Podman
podman run -d \
  --name registry-mirror \
  -p 5000:5000 \
  -v registry-data:/var/lib/registry \
  -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
  docker.io/library/registry:2

# Configure clients to use the mirror
# /etc/containers/registries.conf.d/mirror.conf
cat << 'EOF'
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "localhost:5000"
insecure = true
EOF

# Verify mirror is working
skopeo inspect --tls-verify=false docker://localhost:5000/library/nginx:alpine

# Pre-populate mirror with skopeo sync
skopeo sync --src docker --dest docker \
  --dest-tls-verify=false \
  docker.io/library/nginx \
  localhost:5000/library
```

### Air-Gapped Environment Sync

```bash
#!/bin/bash
# Export images on connected machine
EXPORT_DIR="/media/usb/container-images"
mkdir -p "$EXPORT_DIR"

# List of images to sync
IMAGES=(
  "docker.io/library/nginx:alpine"
  "docker.io/library/postgres:16-alpine"
  "docker.io/library/redis:7-alpine"
  "quay.io/prometheus/prometheus:latest"
)

# Export each image
for img in "${IMAGES[@]}"; do
  name=$(echo "$img" | tr '/:' '_')
  echo "Exporting $img..."
  skopeo copy --all \
    "docker://$img" \
    "oci-archive:${EXPORT_DIR}/${name}.tar"
done

# --- On air-gapped machine ---

# Import each image to local registry
REGISTRY="registry.internal:5000"
for archive in "$EXPORT_DIR"/*.tar; do
  name=$(basename "$archive" .tar | tr '_' '/')
  echo "Importing $name..."
  skopeo copy \
    "oci-archive:$archive" \
    "docker://${REGISTRY}/${name}" \
    --dest-tls-verify=false
done
```

### Registry Authentication Files

```bash
# Auth file locations (in order of precedence)
# 1. --authfile flag
# 2. REGISTRY_AUTH_FILE env var
# 3. ${XDG_RUNTIME_DIR}/containers/auth.json
# 4. ~/.docker/config.json

# Create auth for multiple registries
podman login docker.io
podman login quay.io
podman login registry.internal:5000

# View stored credentials
cat ${XDG_RUNTIME_DIR}/containers/auth.json | jq

# Copy auth file to another system
scp ${XDG_RUNTIME_DIR}/containers/auth.json user@remote:/tmp/auth.json
# On remote: skopeo copy --authfile /tmp/auth.json ...
```

---

## CI/CD Integration with Buildah

### GitHub Actions

```yaml
name: Build and Push with Buildah
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build image
        uses: redhat-actions/buildah-build@v2
        id: build
        with:
          image: myapp
          tags: latest ${{ github.sha }}
          containerfiles: |
            ./Containerfile
          build-args: |
            VERSION=${{ github.sha }}

      - name: Push to registry
        uses: redhat-actions/push-to-registry@v2
        with:
          image: ${{ steps.build.outputs.image }}
          tags: ${{ steps.build.outputs.tags }}
          registry: ghcr.io/${{ github.repository_owner }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Sign with cosign
        run: |
          cosign sign --key env://COSIGN_KEY \
            ghcr.io/${{ github.repository_owner }}/myapp@${{ steps.build.outputs.digest }}
        env:
          COSIGN_KEY: ${{ secrets.COSIGN_KEY }}
```

### GitLab CI

```yaml
build-image:
  stage: build
  image: quay.io/buildah/stable:latest
  variables:
    STORAGE_DRIVER: vfs
    BUILDAH_FORMAT: docker
  script:
    - buildah build
        --build-arg VERSION=${CI_COMMIT_SHORT_SHA}
        -t ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}
        -t ${CI_REGISTRY_IMAGE}:latest
        .
    - buildah login -u ${CI_REGISTRY_USER} -p ${CI_REGISTRY_PASSWORD} ${CI_REGISTRY}
    - buildah push ${CI_REGISTRY_IMAGE}:${CI_COMMIT_SHORT_SHA}
    - buildah push ${CI_REGISTRY_IMAGE}:latest
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

### Jenkins Pipeline

```groovy
pipeline {
    agent {
        kubernetes {
            yaml '''
                spec:
                  containers:
                  - name: buildah
                    image: quay.io/buildah/stable:latest
                    command: ['cat']
                    tty: true
                    securityContext:
                      privileged: true
            '''
        }
    }
    stages {
        stage('Build') {
            steps {
                container('buildah') {
                    sh '''
                        buildah build \
                          --build-arg VERSION=${BUILD_NUMBER} \
                          -t registry.internal:5000/myapp:${BUILD_NUMBER} \
                          -t registry.internal:5000/myapp:latest \
                          .
                    '''
                }
            }
        }
        stage('Push') {
            steps {
                container('buildah') {
                    withCredentials([usernamePassword(
                        credentialsId: 'registry-creds',
                        usernameVariable: 'REG_USER',
                        passwordVariable: 'REG_PASS'
                    )]) {
                        sh '''
                            buildah login -u $REG_USER -p $REG_PASS registry.internal:5000
                            buildah push registry.internal:5000/myapp:${BUILD_NUMBER}
                            buildah push registry.internal:5000/myapp:latest
                        '''
                    }
                }
            }
        }
    }
}
```

### Tekton Tasks

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: buildah-build-push
spec:
  params:
    - name: IMAGE
      description: Image reference to build and push
    - name: CONTAINERFILE
      default: ./Containerfile
  workspaces:
    - name: source
  steps:
    - name: build
      image: quay.io/buildah/stable:latest
      workingDir: $(workspaces.source.path)
      script: |
        buildah build \
          --storage-driver=vfs \
          -f $(params.CONTAINERFILE) \
          -t $(params.IMAGE) .
      volumeMounts:
        - name: varlibcontainers
          mountPath: /var/lib/containers
      securityContext:
        privileged: true
    - name: push
      image: quay.io/buildah/stable:latest
      script: |
        buildah push \
          --storage-driver=vfs \
          $(params.IMAGE)
      volumeMounts:
        - name: varlibcontainers
          mountPath: /var/lib/containers
      securityContext:
        privileged: true
  volumes:
    - name: varlibcontainers
      emptyDir: {}
```

### Security Best Practices for CI/CD

```bash
# 1. Use rootless Buildah in CI
# Set storage driver to vfs (no kernel overlay needed)
export STORAGE_DRIVER=vfs

# 2. Run Buildah without privileges
buildah build --isolation chroot -t myapp .

# 3. Use --no-cache for reproducible builds
buildah build --no-cache -t myapp .

# 4. Scan images before pushing
# With Trivy
trivy image myapp:latest

# With Grype
grype myapp:latest

# 5. Pin base image digests
# FROM nginx:alpine@sha256:abc123...
buildah build -t myapp .

# 6. Use build secrets (don't bake secrets into layers)
buildah build --secret id=npmrc,src=$HOME/.npmrc -t myapp .
# In Containerfile: RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm install

# 7. Minimal images — use multi-stage or scratch
# See "Building from Scratch" section above

# 8. Sign images after build
cosign sign --key cosign.key registry.io/myapp:latest

# 9. Generate and attach SBOM
syft registry.io/myapp:latest -o spdx-json > sbom.json
cosign attach sbom --sbom sbom.json registry.io/myapp:latest
```
