# Sigstore Helper Scripts

This directory contains utility scripts for common Sigstore/Cosign operations.

## Available Scripts

### `install-cosign.sh`
Install cosign binary for your platform.
```bash
./install-cosign.sh                    # Install latest version
./install-cosign.sh 2.2.0              # Install specific version
./install-cosign.sh latest ~/.local/bin # Install to custom path
```

### `sign-image.sh`
Sign container images with cosign (keyless or key-based).
```bash
./sign-image.sh ghcr.io/org/app:latest                    # Keyless signing
./sign-image.sh ghcr.io/org/app:latest --key cosign.key   # Key-based signing
```

### `verify-image.sh`
Verify container image signatures.
```bash
./verify-image.sh ghcr.io/org/app:latest                                    # General verification
./verify-image.sh ghcr.io/org/app:latest user@example.com                   # Verify specific identity
./verify-image.sh ghcr.io/org/app:latest user@example.com https://accounts.google.com
```

### `verify-sbom.sh`
Verify SBOM attestations for container images.
```bash
./verify-sbom.sh ghcr.io/org/app:latest           # Verify and save to verified-sbom.json
./verify-sbom.sh ghcr.io/org/app:latest sbom.json # Verify and save to custom file
```

### `batch-verify.sh`
Batch verify multiple images from a list file.
```bash
# Create image list file
cat > images.txt << EOF
ghcr.io/org/app:v1.0.0
ghcr.io/org/app:v1.1.0
docker.io/library/nginx:latest
EOF

# Verify all images
./batch-verify.sh images.txt

# Verify with specific identity
./batch-verify.sh images.txt user@example.com https://token.actions.githubusercontent.com
```

### `rekor-search.sh`
Search Rekor transparency log for artifacts.
```bash
./rekor-search.sh sha256:abc123...        # Search by digest
./rekor-search.sh ./my-artifact.tar.gz   # Search by file (auto-calculates digest)
```

## Prerequisites

- `cosign` binary (install via `install-cosign.sh` or from https://docs.sigstore.dev/cosign/installation/)
- `rekor-cli` for transparency log searches (optional)
- Docker or other container runtime for image operations

## Environment Variables

These scripts respect standard cosign environment variables:
- `COSIGN_FULCIO_URL` - Custom Fulcio instance URL
- `COSIGN_REKOR_URL` - Custom Rekor instance URL
- `COSIGN_CT_LOG_URL` - Custom CT log URL

## Security Notes

- Keyless signing requires OIDC authentication (opens browser or uses existing token)
- Key-based signing requires access to private key file
- Always verify signatures before deploying images to production
- Use batch verification in CI/CD pipelines for policy enforcement
