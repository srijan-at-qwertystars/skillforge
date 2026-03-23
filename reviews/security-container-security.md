# Review: container-security

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format. Minor markdown bug — missing opening code fence before the NetworkPolicy YAML around line 342.

Excellent skill covering minimal base images (scratch/distroless/alpine), vulnerability scanning (Trivy, Grype, Docker Scout, Snyk), SBOM generation (Syft, CycloneDX, SPDX), image signing (Cosign/Sigstore keyless and key-based), SLSA provenance attestation, container hardening (securityContext, runAsNonRoot, readOnlyRootFilesystem, capability dropping), seccomp profiles (RuntimeDefault, custom Localhost), AppArmor and SELinux, rootless containers (Docker/Podman), Kubernetes Pod Security Standards (Privileged/Baseline/Restricted with namespace labels), secret management (External Secrets Operator), network policies (default-deny), service mesh mTLS (Istio), registry security, admission controllers (Kyverno, OPA Gatekeeper), and CI/CD security pipeline with GitHub Actions.
