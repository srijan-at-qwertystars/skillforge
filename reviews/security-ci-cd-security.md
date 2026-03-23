# Review: ci-cd-security

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format. 501 lines (1 over limit).

Outstanding CI/CD security guide. Covers threat model (4 attack surfaces), GitHub Actions security (least-privilege permissions, SHA pinning, CODEOWNERS, real-world tj-actions compromise reference), secret management (OIDC federation, environment scoping, hygiene rules), dependency security (Dependabot, SCA/Trivy, lockfile pinning, license compliance), SLSA framework (levels table, provenance generation/verification), artifact signing (Cosign/Sigstore keyless, SBOM attachment, GitHub attestations), SAST/DAST integration (CodeQL/Semgrep/Trivy/Snyk/ZAP), pipeline hardening (ephemeral runners, network isolation), PR security (pull_request_target dangers, label-gated workflows), container image security, compliance/auditing (OPA policy-as-code), incident response playbook, and anti-patterns.
