# QA Review: vault-secrets

**Skill path:** `security/vault-secrets/SKILL.md`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with positive AND negative triggers present |
| Under 500 lines | ✅ Pass | 408 lines |
| Imperative voice | ✅ Pass | Commands and instructions use imperative form throughout |
| Examples | ✅ Pass | Every section includes runnable CLI examples with realistic output snippets |
| References linked | ✅ Pass | 3 reference docs (`advanced-patterns.md`, `troubleshooting.md`, `kubernetes-integration.md`) — all exist |
| Scripts linked | ✅ Pass | 3 scripts (`setup-vault-dev.sh`, `vault-backup.sh`, `rotate-secrets.sh`) — all exist |
| Assets linked | ✅ Pass | 5 assets including Helm values, Docker Compose, policy templates, Agent config, GH Actions workflow — all exist |

## B. Content Check — Technical Accuracy

**Verified via web search against official HashiCorp documentation:**

| Topic | Accurate? | Notes |
|-------|-----------|-------|
| KV v2 CLI commands | ✅ | `vault kv put/get/delete/destroy/metadata put` all correct. Uses legacy path syntax (still valid) rather than newer `-mount=` flag |
| Transit engine encrypt/decrypt | ✅ | Base64 requirement, `vault:v1:` ciphertext prefix, key rotation — all correct |
| PKI engine | ✅ | Root CA generation, role creation, cert issuance — correct |
| Database dynamic creds | ✅ | PostgreSQL plugin name, creation_statements template vars (`{{name}}`, `{{password}}`, `{{expiration}}`), lease output — correct |
| AWS secrets engine | ✅ | Config/role/creds flow correct |
| Policy HCL syntax | ✅ | Capabilities list correct (`create`, `read`, `update`, `delete`, `list`, `sudo`, `deny`). `*` as glob (matches all remaining path) and `+` as segment wildcard — both correctly described |
| Auth methods (AppRole, K8s, OIDC, LDAP) | ✅ | Enable/configure/login flows all accurate |
| Vault Agent config | ✅ | Auto-auth, sink, cache, template blocks use correct HCL syntax. Consul Template syntax correct |
| Lease management | ✅ | `vault lease renew/revoke` with `-prefix` — correct |
| Namespaces (Enterprise) | ✅ | `vault namespace create`, `VAULT_NAMESPACE` env var, `X-Vault-Namespace` header — correct |
| HA Raft config | ✅ | `storage "raft"` block with `retry_join`, `api_addr`, `cluster_addr` — correct |
| Audit logging | ✅ | File/syslog/socket types correct. Critical gotcha about audit device blocking correctly noted |
| VSO CRDs | ✅ | `secrets.hashicorp.com/v1beta1` API version confirmed current. VaultConnection, VaultAuth, VaultStaticSecret, VaultDynamicSecret — all correct |
| Seal/Unseal | ✅ | Shamir's Secret Sharing, auto-unseal with KMS — correct |
| Storage backends | ✅ | Raft (recommended), Consul, S3, DynamoDB with correct HA annotations |

### Missing Gotchas / Minor Gaps

1. **Root token security** — No warning to revoke root token after initial setup (security best practice)
2. **`vault login` command** — Not shown; users need to know how to authenticate the CLI
3. **KV v2 `-mount=` flag** — Newer recommended syntax not mentioned (legacy path syntax still works)
4. **KV v2 `patch`/`undelete`/`rollback`** — Useful operations omitted
5. **Check-And-Set (CAS)** — KV v2 concurrent-write safety mechanism not covered
6. **Batch vs service tokens** — Performance-critical distinction not discussed
7. **Secret Zero problem** — AppRole section doesn't mention response-wrapping for initial secret_id delivery

None of these are critical errors — they are completeness gaps in an already comprehensive skill.

## C. Trigger Check

**Positive triggers** (17 terms): All highly specific to HashiCorp Vault — "HashiCorp Vault", "vault secrets", "vault auth method", "vault policy", "dynamic secrets", "vault agent", "vault transit engine", "PKI secrets engine", "vault unseal", "vault namespace", "vault HA", "vault audit", "VaultStaticSecret", "VaultDynamicSecret", "vault approle", "vault OIDC"

**Negative triggers** (6 exclusions): AWS Secrets Manager, Azure Key Vault, GCP Secret Manager, SOPS, sealed-secrets, general encryption without Vault

| False-trigger scenario | Would trigger? | Assessment |
|------------------------|---------------|------------|
| "Store secrets in AWS Secrets Manager" | ❌ No | Correctly excluded |
| "Azure Key Vault rotation policy" | ❌ No | Correctly excluded |
| "How do I manage secrets in my app?" | ❌ No | No positive trigger matched |
| "Set up vault transit encryption" | ✅ Yes | Correct — this is HashiCorp Vault |
| "Kubernetes sealed-secrets with Bitnami" | ❌ No | Correctly excluded |
| "GCP Secret Manager IAM binding" | ❌ No | Correctly excluded |
| "dynamic secrets for database access" | ⚠️ Maybe | "dynamic secrets" alone is slightly ambiguous, but in practice nearly always refers to Vault |

**Verdict:** Triggers are well-crafted with strong specificity and appropriate exclusions.

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5/5 | All CLI commands, HCL syntax, API paths, CRD manifests, and architectural descriptions verified correct against official docs |
| **Completeness** | 4/5 | Covers 6 secrets engines, 5 auth methods, policies, Agent, leases, namespaces, HA, audit, VSO, plus extensive references/scripts/assets. Minor gaps: root token warning, CAS, patch/undelete, secret zero |
| **Actionability** | 5/5 | Every section has copy-pasteable commands with realistic output. Scripts for dev setup, backup, rotation. Helm values, Docker Compose, policy templates ready to use |
| **Trigger quality** | 5/5 | 17 specific positive triggers, 6 competitor exclusions. No realistic false-trigger scenario for competing products |
| **Overall** | **4.75/5** | Production-quality skill with minor completeness gaps |

## E. Verdict

✅ **PASS** — Overall 4.75 ≥ 4.0, no dimension ≤ 2.

No GitHub issues required.

## Recommendations for Future Improvement

1. Add a "Security Gotchas" callout box: root token revocation, response-wrapping for secret zero, VAULT_TOKEN env var hygiene
2. Add `vault kv patch` and `vault kv undelete` to KV v2 section
3. Mention `-mount=` flag as the modern recommended syntax
4. Brief note on batch vs service tokens for high-throughput scenarios
5. Add CAS (Check-And-Set) example for concurrent write safety
