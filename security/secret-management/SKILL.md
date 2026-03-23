---
name: secret-management
description:
  positive: "Use when user manages application secrets, asks about HashiCorp Vault, AWS Secrets Manager/SSM Parameter Store, Azure Key Vault, SOPS, doppler, secret rotation, .env file security, or preventing secrets from leaking into git/logs/builds."
  negative: "Do NOT use for encryption algorithms, TLS certificate management, or OAuth token handling (use jwt-authentication or oauth2-openid-connect skills)."
---

# Secret Management

## Core Principles

- Never hardcode secrets in source code, config files, or container images.
- Apply least privilege — grant minimal access to secrets per service/person.
- Rotate secrets on a schedule and immediately after any suspected compromise.
- Audit every secret access — log who read what, when, from where.
- Encrypt secrets at rest and in transit. Plaintext secrets must never touch disk unencrypted.
- Treat secrets as ephemeral — prefer short-lived, dynamic credentials over long-lived static ones.
- Fail fast — applications must refuse to start if required secrets are missing.

## .env Files and dotenv

Use `.env` files **only for local development**. Never rely on them in production.

```bash
# .gitignore — ALWAYS include these
.env
.env.local
.env.*.local
*.key
*.pem
```

Provide a `.env.example` with placeholder values so developers know what to configure:

```bash
# .env.example — commit this, never real values
DATABASE_URL=postgres://user:password@localhost:5432/mydb
STRIPE_SECRET_KEY=sk_test_XXXXXXXXXXXX
REDIS_URL=redis://localhost:6379
```

Load with validation — fail fast on missing vars:

```python
# Python — pydantic settings
from pydantic_settings import BaseSettings

class Config(BaseSettings):
    database_url: str
    stripe_secret_key: str
    redis_url: str
    class Config:
        env_file = ".env"

config = Config()  # raises ValidationError if any var is missing
```

**Risks of .env in production**: no access control, no rotation, no audit trail, easy to accidentally commit. Use a real secrets manager instead.

## Secret Scanning

### Tools

| Tool | Method | Best For |
|------|--------|----------|
| gitleaks | Regex, 150+ patterns | Pre-commit hooks, CI |
| TruffleHog | Regex + secret validation | Deep scans, legacy repos |
| git-secrets | Pattern matching | AWS credential patterns |
| GitHub Secret Scanning | Push protection | GitHub-hosted repos |

### Pre-commit Hook Setup

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.0
    hooks:
      - id: gitleaks
```

```bash
pip install pre-commit
pre-commit install
```

Native git hook alternative (`.git/hooks/pre-commit`):

```bash
#!/usr/bin/env bash
set -euo pipefail
gitleaks protect --staged --redact
```

### CI Pipeline Scanning

```yaml
# GitHub Actions
- name: Scan for secrets
  uses: gitleaks/gitleaks-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Enable GitHub push protection in repo settings → Code security → Secret scanning → Push protection.

## HashiCorp Vault

### KV Secrets Engine

```bash
# Enable KV v2
vault secrets enable -path=secret kv-v2

# Write a secret
vault kv put secret/myapp/db username="admin" password="s3cret"

# Read a secret
vault kv get -field=password secret/myapp/db
```

### Dynamic Secrets (Database)

```bash
vault secrets enable database
vault write database/config/mydb \
    plugin_name=postgresql-database-plugin \
    connection_url="postgresql://{{username}}:{{password}}@db:5432/mydb" \
    allowed_roles="readonly" username="vault_admin" password="vault_pass"

vault write database/roles/readonly db_name=mydb \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
    VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" max_ttl="24h"

# App requests short-lived credentials
vault read database/creds/readonly
```

### Auth Methods

- **AppRole**: machine-to-machine (CI/CD, services). Use `role_id` + `secret_id`.
- **Kubernetes**: pods authenticate via service account JWT.
- **AWS IAM**: EC2/Lambda authenticate using IAM identity.
- **OIDC/JWT**: integrate with identity providers.

### Policy (Least Privilege)

```hcl
# vault-policy-myapp.hcl
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
path "database/creds/readonly" {
  capabilities = ["read"]
}
# Deny everything else by default
```

```bash
vault policy write myapp vault-policy-myapp.hcl
```

### Vault Agent (Sidecar Pattern)

Inject secrets into pods/VMs automatically via templates:

```hcl
auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = { role = "myapp" }
  }
  sink "file" { config = { path = "/tmp/vault-token" } }
}
template {
  source      = "/etc/vault/templates/config.tpl"
  destination = "/app/config/secrets.env"
}
```

## AWS Secrets Manager / SSM Parameter Store

### Secrets Manager

```bash
# Create
aws secretsmanager create-secret --name myapp/database \
    --secret-string '{"username":"admin","password":"s3cret"}'
# Retrieve
aws secretsmanager get-secret-value --secret-id myapp/database
```

```python
import json, boto3
def get_secret(name: str) -> dict:
    client = boto3.client("secretsmanager")
    return json.loads(client.get_secret_value(SecretId=name)["SecretString"])
```

### Automated Rotation (Lambda)

```bash
aws secretsmanager rotate-secret --secret-id myapp/database \
    --rotation-lambda-arn arn:aws:lambda:us-east-1:123456789:function:rotate-db \
    --rotation-rules '{"ScheduleExpression":"rate(30 days)"}'
```

### SSM Parameter Store (Cost-Effective Alternative)

```bash
# Store as SecureString (encrypted with KMS)
aws ssm put-parameter --name "/myapp/prod/DB_PASSWORD" \
    --value "s3cret" --type SecureString --key-id alias/myapp-key
# Retrieve
aws ssm get-parameter --name "/myapp/prod/DB_PASSWORD" --with-decryption
```

### IAM Policy (Least Privilege)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": "arn:aws:secretsmanager:us-east-1:123456789:secret:myapp/*"
  }]
}
```

## SOPS (Secrets OPerationS)

Encrypt secret files and commit them safely to git. Decrypt at deploy time. Prefer `age` over PGP for simplicity.

```bash
age-keygen -o age.key          # public key: age1xxxxxxxxx
echo "age.key" >> .gitignore   # never commit private keys
```

### .sops.yaml Configuration

```yaml
# .sops.yaml — commit this to repo
creation_rules:
  - path_regex: \.env\.prod\.enc$
    age: >-
      age1prodkey1,age1prodkey2
  - path_regex: \.env\.staging\.enc$
    age: >-
      age1stagingkey1
  - path_regex: \.env\..*\.enc$
    age: >-
      age1devkey1
```

### Usage

```bash
sops --encrypt --in-place secrets.yaml              # Encrypt
sops --decrypt secrets.yaml                          # Decrypt
sops secrets.yaml                                    # Edit (decrypt → editor → re-encrypt)
sops --encrypt --kms "arn:aws:kms:..." secrets.yaml  # Encrypt with AWS KMS
```

### CI/CD Decryption

```yaml
# GitHub Actions
- name: Decrypt secrets
  env:
    SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
  run: |
    sops --decrypt secrets.enc.yaml > secrets.yaml
```

**Key rule**: never commit decrypted files. Add `*.decrypted.*` to `.gitignore`.

## Doppler and SaaS Secret Managers

Doppler provides centralized secret management with environment syncing.

```bash
doppler setup --project myapp --config production  # Configure
doppler run -- node server.js                      # Inject secrets into process
doppler secrets get DATABASE_URL --plain            # Fetch single secret
```

### OIDC Integration (GitHub Actions)

```yaml
jobs:
  deploy:
    permissions:
      id-token: write
    steps:
      - uses: dopplerhq/secrets-fetch-action@v1
        with:
          auth-method: oidc
          doppler-identity-id: ${{ secrets.DOPPLER_IDENTITY_ID }}
          doppler-project: myapp
          doppler-config: production
```

Other SaaS options: Infisical (open-source), 1Password Secrets Automation, Akeyless.

## Kubernetes Secrets

Native K8s secrets are base64-encoded, not encrypted. **Enable etcd encryption at rest.**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secrets
type: Opaque
stringData:
  DB_PASSWORD: "s3cret"
```

### External Secrets Operator

Syncs secrets from external stores (AWS, Vault, Azure) into K8s Secret objects:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: myapp-secrets
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: myapp/database
        property: password
```

### Sealed Secrets (GitOps)

```bash
kubeseal --format yaml < secret.yaml > sealed-secret.yaml  # only cluster can decrypt
```

### Secrets Store CSI Driver

Mount secrets directly as files — secrets never enter etcd:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aws-secrets
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "myapp/database"
        objectType: "secretsmanager"
```

## Secret Rotation Strategies

### Dual-Read (Zero-Downtime) Pattern

1. Generate new credential in the secrets manager.
2. Configure the backend to accept **both** old and new credentials.
3. Deploy application update that reads the new credential.
4. Verify all instances switched over (monitor auth errors).
5. Revoke the old credential.

```python
# Dual-read pattern — try new, fall back to old
def connect_db(secrets: dict) -> Connection:
    for key in ["DB_PASSWORD_NEW", "DB_PASSWORD"]:
        try:
            return psycopg2.connect(password=secrets[key])
        except psycopg2.OperationalError:
            continue
    raise RuntimeError("All database credentials failed")
```

### Rotation Frequencies

| Secret Type | Recommended Interval |
|-------------|---------------------|
| Database passwords | 30–90 days |
| API keys | 90 days |
| Service account tokens | 24 hours (use dynamic) |
| SSH keys | 90–180 days |
| Encryption keys | Annually (with re-encryption) |

### Automated Rotation Checklist

- Secrets manager triggers rotation (Lambda, CronJob, Vault lease).
- New credential tested before old one is revoked.
- Application hot-reloads or restarts to pick up new values.
- Monitoring alerts on auth failure spikes post-rotation.
- Rollback procedure documented and tested.

## CI/CD Secrets

### GitHub Actions

```yaml
env:
  DB_PASSWORD: ${{ secrets.DB_PASSWORD }}  # secrets are masked in logs
steps:
  - run: ./deploy.sh
```

Use **OIDC** for cloud providers — eliminates static credentials:

```yaml
# GitHub Actions — use OIDC for cloud providers instead of static credentials
permissions:
  id-token: write
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::123456789:role/deploy
      aws-region: us-east-1
```

### GitLab CI Variables

Set variables in Settings → CI/CD → Variables with **masked** + **protected** flags. Scope to specific environments/branches.

### Rules for CI/CD Secrets

- Mask all secret variables in logs. Scope secrets to specific environments/branches.
- Prefer OIDC over static credentials for cloud access.
- Never pass secrets as CLI arguments (visible in process lists).
- Rotate CI/CD secrets on the same schedule as application secrets.

## Application Patterns

### Config Struct (Single Source of Truth)

```go
type Secrets struct {
    DBPassword string `json:"db_password" validate:"required"`
    APIKey     string `json:"api_key" validate:"required"`
    JWTSecret  string `json:"jwt_secret" validate:"required,min=32"`
}

func MustLoadSecrets() Secrets {
    var s Secrets
    if err := loadFromVault(&s); err != nil {
        log.Fatalf("FATAL: cannot load secrets: %v", err)
    }
    return s
}
```

### Never Log Secrets

```python
import logging, re

class SecretFilter(logging.Filter):
    PATTERNS = [re.compile(r'(?i)(password|secret|token|api_key)\s*[=:]\s*\S+')]
    def filter(self, record):
        msg = record.getMessage()
        for p in self.PATTERNS:
            msg = p.sub(r'\1=***REDACTED***', msg)
        record.msg, record.args = msg, ()
        return True
```

Sanitize error messages — strip connection strings before returning or logging errors.

## Incident Response: Secret Leak Playbook

Execute these steps **immediately** when a secret is found in git, logs, or any public surface:

1. **Revoke** the leaked credential — disable it at the provider within minutes.
2. **Rotate** — issue a new credential and deploy it to all consumers.
3. **Scan** — run `gitleaks detect --source . --log-opts --all` to find other leaked secrets.
4. **Purge** from git history if committed:
   ```bash
   # Remove secret from all git history
   git filter-repo --invert-paths --path secrets.env
   # Force-push to all remotes (coordinate with team)
   git push --force --all
   ```
5. **Audit** — review access logs for unauthorized use during the exposure window.
6. **Notify** — inform security team, affected users, and compliance if PII was exposed.
7. **Post-mortem** — document root cause, add scanning to prevent recurrence.

**Key rule**: assume any leaked secret has been compromised. Always rotate, never just delete.
