# Sigstore References

## Official Documentation

- **Sigstore Docs** - https://docs.sigstore.dev/
  - Main documentation hub for all Sigstore projects
  - Getting started guides, tutorials, and API references

## Core Tools & Repositories

### Cosign
- **Repository**: https://github.com/sigstore/cosign
- **Documentation**: https://docs.sigstore.dev/cosign/
- **Releases**: https://github.com/sigstore/cosign/releases
- **Purpose**: Container signing, verification, and storage in OCI registries

### Fulcio
- **Repository**: https://github.com/sigstore/fulcio
- **Documentation**: https://docs.sigstore.dev/fulcio/
- **Purpose**: Free code signing certificate authority using OIDC identities
- **Public Instance**: https://fulcio.sigstore.dev

### Rekor
- **Repository**: https://github.com/sigstore/rekor
- **Documentation**: https://docs.sigstore.dev/rekor/
- **Purpose**: Immutable transparency log for signed software artifacts
- **Public Instance**: https://rekor.sigstore.dev
- **Search UI**: https://search.sigstore.dev

### Policy Controller
- **Repository**: https://github.com/sigstore/policy-controller
- **Documentation**: https://docs.sigstore.dev/policy-controller/
- **Purpose**: Kubernetes admission controller for enforcing signature policies

## Related Tools & Ecosystem

### Gitsign
- **Repository**: https://github.com/sigstore/gitsign
- **Purpose**: Keyless Git commit signing using Sigstore

### Sigstore Python
- **Repository**: https://github.com/sigstore/sigstore-python
- **Purpose**: Python client library for Sigstore signing/verification

### Sigstore JavaScript
- **Repository**: https://github.com/sigstore/sigstore-js
- **Purpose**: JavaScript/TypeScript client for Sigstore

### Rekor CLI
- **Repository**: https://github.com/sigstore/rekor/tree/main/cmd/rekor-cli
- **Purpose**: CLI for interacting with Rekor transparency log

## Standards & Specifications

- **SLSA (Supply Chain Levels for Software Artifacts)**: https://slsa.dev/
  - Sigstore is a key component for achieving SLSA compliance
- **In-Toto**: https://in-toto.io/
  - Framework for securing software supply chains
- **TUF (The Update Framework)**: https://theupdateframework.io/
  - Used for secure distribution of Sigstore root keys

## Community & Resources

- **Sigstore Blog**: https://blog.sigstore.dev/
- **Sigstore Slack**: https://sigstore.slack.com (join via https://slack.sigstore.dev)
- **Mailing List**: https://groups.google.com/g/sigstore-dev
- **GitHub Organization**: https://github.com/sigstore

## Security & Trust

- **Root of Trust**: https://sigstore-tuf-root.storage.googleapis.com
- **Certificate Transparency**: All Fulcio certificates are logged to Rekor
- **Security Policy**: https://github.com/sigstore/.github/blob/main/SECURITY.md
- **Vulnerability Disclosure**: security@sigstore.dev

## Integration Guides

- **GitHub Actions**: https://docs.sigstore.dev/cosign/github-actions/
- **GitLab CI**: https://docs.sigstore.dev/cosign/gitlab/
- **Kubernetes**: https://docs.sigstore.dev/policy-controller/overview/
- **Tekton Chains**: https://tekton.dev/docs/chains/

## Learning Resources

- **Sigstore Quick Start**: https://docs.sigstore.dev/getting-started/
- **Cosign Tutorial**: https://docs.sigstore.dev/cosign/quickstart/
- **Keyless Signing Guide**: https://docs.sigstore.dev/cosign/keyless/
- **Verification Patterns**: https://docs.sigstore.dev/cosign/verify/
