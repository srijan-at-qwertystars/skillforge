# Vault CI/CD Policy — Read-only access for CI/CD pipelines
# Assign to: GitHub Actions, GitLab CI, Jenkins, ArgoCD service accounts
# Customize: Replace paths with your application secret paths

# KV v2 — Read deployment secrets
path "secret/data/ci/*" {
  capabilities = ["read"]
}
path "secret/metadata/ci/*" {
  capabilities = ["read", "list"]
}

# KV v2 — Read application configs for deployment
path "secret/data/apps/+/deploy" {
  capabilities = ["read"]
}

# AWS — Get temporary credentials for deployment
path "aws/creds/ci-deploy" {
  capabilities = ["read"]
}

# PKI — Issue short-lived certificates for deployment verification
path "pki/issue/ci-certs" {
  capabilities = ["create", "update"]
}

# Transit — Sign artifacts
path "transit/sign/ci-signing-key" {
  capabilities = ["update"]
}
path "transit/verify/ci-signing-key" {
  capabilities = ["update"]
}

# Token — Self-management only
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
