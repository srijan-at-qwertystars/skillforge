# Review: secret-management

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format.

Outstanding secret management skill. Covers core principles, .env files (gitignore, .env.example, pydantic validation), secret scanning (gitleaks, TruffleHog, git-secrets, GitHub push protection), HashiCorp Vault (KV v2, dynamic database secrets, auth methods, policies, Vault Agent sidecar), AWS Secrets Manager and SSM Parameter Store (with rotation Lambda, IAM least privilege), SOPS (age encryption, .sops.yaml, CI/CD decryption), Doppler (OIDC integration), Kubernetes secrets (External Secrets Operator, Sealed Secrets, Secrets Store CSI Driver), secret rotation strategies (dual-read zero-downtime pattern, frequency table), CI/CD secrets (GitHub Actions OIDC, GitLab variables), application patterns (config struct, log redaction), and incident response playbook (revoke, rotate, scan, purge, audit, notify, post-mortem).
