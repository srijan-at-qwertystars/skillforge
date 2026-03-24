# QA Review: vault-secrets

**Skill path:** `~/skillforge/security/vault-secrets/`
**Review date:** 2025-07-18
**Reviewer:** Copilot QA

---

## Scores

| Dimension      | Score | Notes |
|----------------|-------|-------|
| Accuracy       | 4/5   | All Vault commands, API paths, and HCL syntax are correct. Deductions: hardcoded install version `1.15.6` is outdated (latest stable is 1.21.x); Docker images reference `1.18.3` which is also behind; `docker-compose-vault.yml` uses Consul storage backend which HashiCorp now considers a legacy path in favor of Raft; `funzip` in the install command is uncommon (most systems have `unzip` but not `funzip`). |
| Completeness   | 5/5   | Exceptional breadth and depth. SKILL.md covers all major secrets engines (KV v2, PKI, Transit, Database, AWS, SSH), 7 auth methods, policies/ACLs, dynamic secrets, leases, Vault Agent, K8s integration (Injector, CSI, VSO), namespaces, HA/Raft, auto-unseal, monitoring, and audit. References add advanced patterns (secret zero, response wrapping, control groups, Sentinel, replication, batch/service tokens, identity, OIDC provider, Terraform), 10+ troubleshooting scenarios, and deep K8s integration guide with comparison matrix. Scripts are production-ready. Assets include policies, agent config, two docker-compose stacks, GitHub Actions workflow, and Helm values. |
| Actionability  | 5/5   | Every concept has copy-paste working examples. Scripts have proper argument parsing, error handling, logging, and usage headers. Policy templates are ready to customize. Docker-compose files stand up complete environments (HA Raft + monitoring, Consul + Agent demo). GitHub Actions workflow shows JWT, AppRole, and multi-env patterns. Helm values are production-grade with TLS, auto-unseal, anti-affinity, and service monitors. |
| Trigger quality| 4/5   | Good positive triggers covering secrets engines, auth methods, Agent, policies, K8s integration. Negative triggers correctly exclude AWS Secrets Manager, password managers, plain K8s Secrets, and general config management. Minor gaps: no mention of HCP Vault (managed offering), OpenBao (Vault fork), or Vault Proxy (newer component replacing Agent's API proxy mode). |

**Overall: 4.5 / 5.0**

---

## Structure Check

- [x] YAML frontmatter has `name` and `description`
- [x] Positive triggers present (secrets engines, auth methods, Agent, policies, K8s, namespaces)
- [x] Negative triggers present (env vars, AWS Secrets Manager, 1Password/Bitwarden, plain K8s Secrets)
- [x] Body under 500 lines (495 lines — just within limit)
- [x] Imperative voice used throughout
- [x] Code examples for every major section
- [x] Resources section links references, scripts, and assets from SKILL.md

---

## Content Verification

### Claims verified accurate ✅
- KV v2 `-mount=` flag syntax is correct and modern
- Transit encrypt requires base64-encoded plaintext — correct
- Database dynamic credentials output format (username, password, lease_id) — correct
- PKI intermediate CA signing flow — correct
- AppRole login flow (role_id + secret_id → token) — correct
- Raft HA configuration with retry_join — correct
- Auto-unseal with AWS KMS seal stanza — correct
- Vault Agent `auto_auth` is NOT deprecated (only Agent's `api_proxy` stanza is deprecated) — skill usage is valid
- Policy capabilities list (create, read, update, delete, list, sudo, deny) — correct
- KV v2 policy paths require `secret/data/` and `secret/metadata/` — correctly documented

### Issues found

1. **Outdated install version (minor):** Line 21 hardcodes `vault/1.15.6/vault_1.15.6_linux_amd64.zip`. Current stable is 1.21.x. Consider using a variable or noting users should check latest version.

2. **`funzip` dependency (minor):** The install command uses `funzip` which is part of the `unzip` package and not available by default on many systems. Standard approach is `unzip` to a temp directory.

3. **Docker image version (minor):** All Docker assets reference `hashicorp/vault:1.18.3`. While functional, users may want the latest. Consider noting version pinning is intentional.

4. **Consul backend in docker-compose-vault.yml (minor):** This compose file uses `storage "consul"` which is a legacy path. HashiCorp now recommends Raft integrated storage. The file is still valid as a demo but could mislead users into choosing Consul for new deployments.

5. **No mention of Vault Proxy (minor):** Vault Agent's API proxy mode is now deprecated in favor of the standalone Vault Proxy component. The skill covers Agent templating (still valid) but doesn't mention Proxy for API proxying use cases.

6. **No BSL/license mention (informational):** Vault transitioned from MPL to BSL (Business Source License) in 2023. Users evaluating Vault should be aware of licensing implications.

---

## Trigger Analysis

### Would correctly trigger for:
- "Set up Vault KV secrets for my app"
- "Configure AppRole auth in Vault"
- "Vault Agent auto-auth Kubernetes"
- "Transit encryption with Vault"
- "Rotate database credentials with Vault"
- "Vault PKI certificate authority"
- "Vault policy for read-only access"
- "Deploy Vault HA cluster with Raft"

### Would correctly NOT trigger for:
- "Store API keys in environment variables"
- "Use AWS Secrets Manager for my Lambda"
- "Set up 1Password for the team"
- "Kubernetes Secrets for ConfigMap"
- "Application configuration with Spring Cloud Config"

### Potential edge cases:
- "HCP Vault setup" — would trigger (has "Vault") but skill doesn't cover HCP-specific setup
- "OpenBao secrets management" — would NOT trigger, but content is largely applicable (OpenBao is a Vault fork)
- "Vault Proxy configuration" — would trigger on "Vault" but Proxy is not covered

---

## Files Reviewed

| File | Lines | Status |
|------|-------|--------|
| SKILL.md | 495 | ✅ Well-structured, comprehensive |
| references/advanced-patterns.md | 1120 | ✅ Deep coverage of enterprise patterns |
| references/troubleshooting.md | 831 | ✅ Practical diagnostic workflows |
| references/kubernetes-integration.md | 1187 | ✅ All 4 K8s methods with comparison |
| scripts/setup-vault.sh | 283 | ✅ Production-quality, dev+prod modes |
| scripts/rotate-secrets.sh | 216 | ✅ Zero-downtime rotation with verification |
| scripts/setup-vault-dev.sh | 245 | ✅ Quick dev setup with sample data |
| scripts/vault-backup.sh | 158 | ✅ Raft snapshots with S3 + rotation |
| assets/vault-policy.hcl | 309 | ✅ 7 reusable policy templates |
| assets/vault-agent-config.hcl | 179 | ✅ Production agent with templates |
| assets/docker-compose.yml | 281 | ✅ 3-node HA + Prometheus + Grafana |
| assets/docker-compose-vault.yml | 153 | ⚠️ Uses deprecated Consul backend |
| assets/github-actions-vault.yml | 158 | ✅ JWT + AppRole + multi-env patterns |
| assets/vault-helm-values.yaml | 258 | ✅ Production Helm with TLS + KMS |
| assets/vault-policy-templates/*.hcl | 4 files | ✅ Ready-to-use role policies |

---

## Recommendations

1. Update the install command to reference a current version or use a generic approach
2. Add a brief note about Vault Proxy for API proxy use cases
3. Consider adding a note that `docker-compose-vault.yml` uses Consul for demo purposes and Raft is preferred for production
4. Add HCP Vault and Vault Proxy to the description's trigger terms

---

## Verdict

**PASS** — High-quality, comprehensive skill with minor version-pinning issues. No blocking problems. All examples are syntactically correct and follow current Vault best practices.