---
name: ci-cd-security
description:
  positive: "Use when user secures CI/CD pipelines, asks about GitHub Actions security, secret management in CI, supply chain security, SLSA, artifact signing, dependency scanning, or pipeline hardening."
  negative: "Do NOT use for application-level security (OWASP), container runtime security (use container-security skill), or secret management tools without CI/CD context (use secret-management skill)."
---

# CI/CD Pipeline Security

## CI/CD Threat Model

Understand the four primary attack surfaces before applying controls:

- **Compromised dependencies**: Attacker poisons an upstream package or action (e.g., tj-actions/changed-files compromise, March 2025). Malicious code runs inside your build.
- **Stolen secrets**: Credentials exfiltrated via logs, environment dumps, or untrusted PR code accessing repository secrets.
- **Tampered artifacts**: Build outputs modified after compilation but before deployment. No cryptographic proof of origin.
- **Poisoned pipelines**: Attacker modifies workflow definitions, build scripts, or CI config to inject malicious steps that persist across builds.

Map every CI/CD component (source, build, deploy, artifact store) to these threats. Prioritize controls that cut across multiple vectors.

## GitHub Actions Security

### Set Least-Privilege Permissions

Default `GITHUB_TOKEN` to read-only at the workflow level. Elevate per-job only when required:

```yaml
# Top-level: restrict everything
permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
      - run: npm test

  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write      # only this job needs write
      id-token: write      # OIDC for signing
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - run: npm publish
```

### Pin Actions by SHA

Never reference actions by mutable tag. Tags can be repointed to malicious commits:

```yaml
# BAD — mutable tag
- uses: actions/setup-node@v4

# GOOD — immutable SHA with version comment
- uses: actions/setup-node@1e60f620b9541d16bece96c5465dc8ee9832be0b # v4.0.3
```

Enable Dependabot for the `github-actions` ecosystem to auto-update pinned SHAs:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

Enforce SHA pinning at the organization level via GitHub Actions policies.

### Protect Workflow Files

- Add `.github/` to `CODEOWNERS` requiring security team review for workflow changes.
- Enable branch protection on the default branch with required reviews.
- Require signed commits for workflow modifications.

```
# .github/CODEOWNERS
/.github/workflows/ @org/security-team
/.github/actions/   @org/security-team
```

## Secret Management in CI

### Use GitHub Encrypted Secrets

- Scope secrets to the narrowest level: environment > repository > organization.
- Prefer environment secrets with required reviewers for production deployments.
- Never echo secrets. GitHub auto-masks registered secrets, but derived values are not masked.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production    # requires approval
    steps:
      - run: |
          # Mask derived values explicitly
          echo "::add-mask::$DERIVED_TOKEN"
```

### Use OIDC Instead of Static Credentials

Replace long-lived cloud credentials with OIDC federation. Tokens are short-lived and job-scoped:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
    with:
      role-to-assume: arn:aws:iam::123456789012:role/ci-deploy
      aws-region: us-east-1
      # No static AWS_ACCESS_KEY_ID needed
```

### Secret Hygiene Rules

Rotate secrets every 90 days max. Run secret scanning with push protection (GitHub, GitGuardian, TruffleHog). Audit secret access via GitHub audit logs. Never pass secrets via environment variables to untrusted steps — use `env:` scoping per-step.

## Dependency Security

### Automated Updates

Configure Dependabot or Renovate for all ecosystems. Enforce lockfile updates:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: npm
    directory: /
    schedule:
      interval: daily
    open-pull-requests-limit: 10
    reviewers:
      - org/security-team
```

### SCA Scanning

Run Software Composition Analysis on every PR:

```yaml
jobs:
  sca:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - uses: aquasecurity/trivy-action@915b19bbe73b92a6cf82a1bc12b087c9a19a5fe2 # v0.28.0
        with:
          scan-type: fs
          severity: CRITICAL,HIGH
          exit-code: 1
```

### Lockfile Pinning

Commit lockfiles (`package-lock.json`, `go.sum`, `Cargo.lock`). Use `--frozen-lockfile` / `--ci` flags in CI to fail on lockfile drift. Verify lockfile integrity checksums.

### License Compliance

Integrate license scanning (FOSSA, Licensee, Trivy) to block copyleft or unknown licenses before merge.

## SLSA Framework

SLSA (Supply-chain Levels for Software Artifacts) defines increasing integrity guarantees:

| Level | Requirement | What It Proves |
|-------|-------------|----------------|
| 1 | Build provenance exists | Someone built it somewhere |
| 2 | Signed provenance from hosted build | Authenticated build service |
| 3 | Hardened, isolated build on ephemeral environment | Tamper-resistant build process |

### Generate SLSA Provenance with GitHub

Use the official SLSA generator to reach Level 3:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      digest: ${{ steps.hash.outputs.digest }}
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - run: go build -o myapp .
      - id: hash
        run: echo "digest=$(sha256sum myapp | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"
      - uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08 # v4.6.0
        with:
          name: myapp
          path: myapp

  provenance:
    needs: build
    permissions:
      actions: read
      id-token: write
      contents: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.1.0
    with:
      base64-subjects: "${{ needs.build.outputs.digest }}"
```

### Verify Provenance Before Deployment

```bash
slsa-verifier verify-artifact myapp \
  --provenance-path myapp.intoto.jsonl \
  --source-uri github.com/org/repo \
  --source-tag v1.2.3
```

## Artifact Signing

### Sign Container Images with Cosign (Sigstore)

Sigstore provides keyless signing using OIDC identity from the CI provider:

```yaml
jobs:
  sign:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      packages: write
    steps:
      - uses: sigstore/cosign-installer@dc72c7d5c4d10cd6bcb8cf6e3fd625a9e5e537da # v3.7.0
      - run: |
          cosign sign --yes ghcr.io/org/app@sha256:${{ steps.build.outputs.digest }}
```

### Attach SBOM to Signed Image

```bash
# Generate SBOM
syft ghcr.io/org/app:latest -o spdx-json > sbom.spdx.json

# Attach and sign
cosign attest --yes --predicate sbom.spdx.json \
  --type spdxjson ghcr.io/org/app@sha256:abc123
```

### GitHub Artifact Attestations

Use native GitHub attestations for non-container artifacts:

```yaml
- uses: actions/attest-build-provenance@v2
  with:
    subject-path: dist/myapp
```

Verify downstream:

```bash
gh attestation verify dist/myapp --repo org/repo
```

## SAST/DAST Integration

Choose the right tool for each stage:

| Tool | Type | When to Run | Best For |
|------|------|-------------|----------|
| CodeQL | SAST | PR + scheduled weekly | Language-specific deep analysis |
| Semgrep | SAST | PR (fast) | Custom rules, pattern matching |
| Trivy | SCA + container | PR + build | Vulnerabilities in deps and images |
| Snyk | SCA + SAST | PR | License + vuln combo |
| OWASP ZAP | DAST | Post-deploy to staging | Runtime web vulnerabilities |

### CodeQL Integration

```yaml
jobs:
  codeql:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - uses: github/codeql-action/init@v3
        with:
          languages: javascript
      - uses: github/codeql-action/analyze@v3
```

Run SAST on every PR for fast feedback. Run DAST on staging environments post-deploy. Schedule full SCA scans weekly to catch newly disclosed CVEs.

## Pipeline Hardening

### Least Privilege

- Grant only required permissions per job (not per workflow).
- Use separate service accounts per environment (dev/staging/prod).
- Restrict who can trigger manual workflows via environment protection rules.

### Ephemeral Environments

- Use GitHub-hosted runners or ephemeral self-hosted runners that reset after each job.
- Never persist state between jobs on the runner filesystem.
- Clean workspace explicitly if using persistent runners.

### Immutable Runners

Build runner images from a hardened base via IaC. Disable outbound network except required registries. Run runners in isolated network segments.

### Network Isolation

```yaml
# Use GitHub's larger runners with private networking
jobs:
  deploy:
    runs-on:
      group: private-network-runners
      labels: [ubuntu-latest-4core]
```

Restrict runner egress to allowlisted domains. Use HTTPS inspection proxies for audit trails on outbound traffic.

## Pull Request Security

### Fork Restrictions

Never run `pull_request_target` with `actions/checkout` of fork code plus secret access:

```yaml
# DANGEROUS — fork code with secrets
on: pull_request_target
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}  # fork code
      - run: deploy.sh  # has access to secrets — DO NOT DO THIS

# SAFE — gate on trusted contributors
jobs:
  build:
    if: github.event.pull_request.head.repo.fork == false
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
```

### Label-Gated Workflows

Require a trusted maintainer to add a label before CI runs on external contributions:

```yaml
on:
  pull_request:
    types: [labeled]

jobs:
  ci:
    if: contains(github.event.pull_request.labels.*.name, 'safe-to-test')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11
      - run: make test
```

### Required Reviews

Enforce at least 2 reviewers for `.github/workflows/` changes. Require CODEOWNERS approval. Dismiss stale approvals on new pushes. Block merge without passing required status checks.

## Container Image Security in CI

### Base Image Scanning

Scan base images before building on top of them:

```yaml
steps:
  - uses: aquasecurity/trivy-action@915b19bbe73b92a6cf82a1bc12b087c9a19a5fe2
    with:
      image-ref: node:22-slim
      severity: CRITICAL,HIGH
      exit-code: 1
```

### Multi-Stage Builds

Separate build dependencies from runtime to minimize attack surface:

```dockerfile
FROM node:22-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --ignore-scripts
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs22-debian12
COPY --from=build /app/dist /app
CMD ["/app/server.js"]
```

### Distroless and Minimal Images

Use distroless or Alpine-based images for production. Remove shells, package managers, and debug tools from final images. Pin base image digests, not tags:

```dockerfile
FROM gcr.io/distroless/static-debian12@sha256:abc123def456...
```

## Compliance and Auditing

### Audit Logs

Stream GitHub audit logs to a SIEM (Splunk, Datadog, Sentinel). Monitor for workflow file changes, secret access, permission escalations, new collaborator additions. Retain for compliance period (1–7 years).

### Policy-as-Code

Enforce pipeline policies programmatically with OPA or Gatekeeper:

```rego
# policy/ci_security.rego
package ci.security

deny[msg] {
  input.permissions.contents == "write"
  input.trigger == "pull_request_target"
  msg := "pull_request_target must not have contents:write"
}

deny[msg] {
  action := input.steps[_].uses
  not contains(action, "@")
  msg := sprintf("Action %s must be pinned by SHA", [action])
}
```

### Required Checks

- Configure branch protection to require security checks (SAST, SCA, secret scan) to pass before merge.
- Use GitHub rulesets for org-wide enforcement.
- Block deployments without signed provenance attestation.

## Incident Response

### Compromised Pipeline Playbook

1. **Contain**: Disable the compromised workflow immediately. Revoke all secrets the workflow could access.
2. **Assess**: Determine blast radius — which artifacts were built by the compromised pipeline. Check audit logs for unauthorized secret access.
3. **Rotate**: Rotate every secret the pipeline had access to, including OIDC trust relationships if the identity provider was compromised.
4. **Remediate**: Pin the offending action to a known-good SHA. Rebuild and re-sign all artifacts produced during the compromise window.
5. **Notify**: Alert downstream consumers. Publish a security advisory if public artifacts were affected.
6. **Harden**: Add the missing control that allowed the compromise (SHA pinning, permission restriction, fork protection).

### Secret Rotation Procedure

1. Generate new credential. Update in GitHub via `gh secret set`. Update in target system.
2. Verify pipeline works with new secret. Revoke old secret. Log the rotation event.

### Blast Radius Containment

- Scope secrets to single repositories and environments, never org-wide.
- Use separate credentials per deployment target.
- Tag all artifacts with build metadata (commit SHA, workflow run ID) to identify potentially compromised outputs.

## Anti-Patterns

### Over-Permissive Tokens

```yaml
# WRONG — grants full repo access to every job
permissions: write-all

# RIGHT — explicit minimal permissions per job
permissions:
  contents: read
```

### Secrets in Environment

Never store secrets in `env:` at the workflow level where all jobs inherit them. Never log `${{ secrets.* }}` or pass them to untrusted actions. Never use secrets in `run:` blocks that pipe to files or network endpoints without masking.

### Self-Hosted Runner Risks

- Self-hosted runners persist between jobs by default — malware or credential theft carries across builds.
- Use ephemeral runners (scale-to-zero with actions-runner-controller).
- Never run self-hosted runners on shared infrastructure without network isolation.
- Never allow public repositories to use self-hosted runners — any fork PR can execute arbitrary code on them.

### Other Anti-Patterns

- Using `pull_request_target` with fork checkout — grants fork code access to secrets.
- Skipping lockfile verification — allows dependency confusion attacks.
- Running security scans only on the default branch — misses vulnerabilities in PRs.
- Using `npm install` instead of `npm ci` — ignores lockfile.
