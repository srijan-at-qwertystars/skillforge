# QA Review: azure-bicep

**Skill path:** `cloud/azure-bicep/`
**Reviewed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ | `azure-bicep` |
| YAML frontmatter `description` | ✅ | Comprehensive, lists all covered topics |
| Positive triggers | ✅ | "Bicep", "Azure IaC", "ARM template", "Azure deployment", ".bicep file", "deployment stack" |
| Negative triggers | ✅ | NOT Terraform, NOT Pulumi, NOT AWS CloudFormation, NOT Azure CLI scripting, NOT plain ARM JSON |
| Body under 500 lines | ✅ | 480 lines (tight but compliant) |
| Imperative voice | ✅ | "Pin API versions", "Use `@secure()`", "Prefer interpolation", "Set `targetScope` explicitly" |
| Examples with I/O | ✅ | 2 examples with **Input** prompt and **Output** Bicep code |
| Resources properly linked | ✅ | 3 references, 3 scripts, 5 assets — all with markdown table links and descriptions |

**Structure score: 8/8 criteria met.**

---

## B. Content Check

### Syntax Accuracy (verified via web search against Microsoft docs)

| Feature | Status | Notes |
|---|---|---|
| Resource declarations | ✅ | `resource <sym> '<type>@<version>' = { ... }` syntax correct |
| Module syntax (local) | ✅ | `module <sym> './path.bicep' = { name, params }` correct |
| Module syntax (registry `br:`) | ✅ | `br:acr.azurecr.io/path:version` and `br/public:` alias correct |
| Module syntax (template specs `ts:`) | ✅ | `ts:{subId}/{rg}/{name}:{version}` correct |
| Deployment scopes | ✅ | `targetScope` with all 4 values, cross-scope module `scope:` correct |
| User-defined types | ✅ | `type`, `@export()`, nullable `?`, string literal unions all correct |
| `@discriminator` | ✅ | Syntax matches Microsoft docs; discriminator on union types correct |
| Deployment stacks CLI | ✅ | `az stack group create`, `az stack sub create`, `az stack mg create` all correct |
| `--deny-settings-mode` values | ✅ | `none`, `denyDelete`, `denyWriteAndDelete` correct |
| `--action-on-unmanage` values | ✅ | `detachAll`, `deleteResources`, `deleteAll` correct |
| What-if operations | ✅ | `az deployment group what-if`, `--result-format FullResourcePayloads` correct |
| Conditional deployment | ✅ | `= if (condition) { ... }` syntax correct |
| Loops | ✅ | Array, index, condition, property loops all syntactically correct |
| Import/export | ✅ | `import { x } from './file.bicep'` and wildcard `import * as` correct |
| `.bicepparam` files | ✅ | `using './main.bicep'` syntax correct |
| Extension syntax | ✅ | Uses modern `extension` keyword (not deprecated `provider`). Correct. |

### Bicep CLI Commands

| Command | Status | Notes |
|---|---|---|
| `bicep build` | ✅ | Correct |
| `bicep build-params` | ✅ | Correct |
| `bicep decompile` | ✅ | Correct |
| `bicep lint` | ✅ | Correct |
| `bicep format` | ✅ | Correct |
| `bicep publish` | ✅ | Correct |
| `bicep restore` | ✅ | Correct |
| `bicep generate-params` | ✅ | Correct |
| `bicep test` | ⚠️ | Experimental/preview feature; skill presents it as standard. Functional but should note experimental status. |
| `az bicep install/upgrade` | ✅ | Correct |

### API Versions

| Resource Type | Skill Version | Latest Stable | Status |
|---|---|---|---|
| `Microsoft.Storage/storageAccounts` | `2023-05-01` | `2025-06-01` | ⚠️ Behind by ~2 years; still functional |
| `Microsoft.Web/sites` | `2023-12-01` | `2023-12-01` | ✅ Current |
| `Microsoft.Web/serverfarms` | `2023-12-01` | `2023-12-01` | ✅ Current |
| `Microsoft.Sql/servers` | `2023-08-01-preview` | — | ⚠️ Preview version used; acceptable for examples |
| `Microsoft.KeyVault/vaults` | `2023-07-01` | `2023-07-01` | ✅ Current |
| `Microsoft.Network/virtualNetworks` | `2023-11-01` | Recent | ✅ Acceptable |
| `Microsoft.Insights/components` | `2020-02-02` | `2020-02-02` | ✅ Current (no newer stable) |
| `Microsoft.Resources/deploymentScripts` | `2023-08-01` | Recent | ✅ Acceptable |

### Reference Files Quality

- **advanced-patterns.md** (665 lines): Excellent coverage of deployment scripts, extensibility providers, private registries, template specs, deployment stacks with deny settings, what-if, cross-scope, managed identity, `@discriminator` advanced patterns, and Azure service patterns (AKS, App Service, Functions, SQL).
- **troubleshooting.md** (406 lines): Comprehensive error-by-error guide with causes/fixes tables, debugging techniques, API version compatibility, decompilation issues, linter suppression.
- **resource-reference.md** (~500 lines): Production-ready patterns for 10 common resource types with security defaults.

### Script Quality

- **setup-bicep.sh**: Proper `set -euo pipefail`, argument parsing, idempotent project init, VS Code extension install.
- **deploy-bicep.sh**: Full lint→validate→what-if→deploy pipeline with stack support, environment targeting, confirmation prompt.
- **lint-bicep.sh**: Multi-mode linting with `--strict`, `--fix`, `--ci`, best-practices checks, Azure validation.

### Asset Quality

- **main.bicep**: Production-grade multi-resource template (App Service + SQL + KV + App Insights) with managed identity, RBAC, Key Vault references.
- **modules/storage.bicep**: Parameterized with lifecycle, versioning, soft delete, network ACLs.
- **modules/networking.bicep**: VNet + dynamic subnets + per-subnet NSGs with security rules.
- **bicepconfig.json**: All 35 built-in linter rules configured.
- **pipeline.yml**: Dual GH Actions + Azure DevOps with OIDC auth, environment gates.

---

## C. Trigger Check

### Should trigger ✅

| Query | Would trigger? |
|---|---|
| "Write a Bicep file for a storage account" | ✅ matches "Bicep" |
| "Azure IaC for my web app" | ✅ matches "Azure IaC" |
| "Create a .bicep file" | ✅ matches ".bicep file" |
| "Set up a deployment stack" | ✅ matches "deployment stack" |
| "Convert ARM template to Bicep" | ✅ matches "ARM template" + "Bicep" |
| "Azure deployment automation" | ✅ matches "Azure deployment" |

### Should NOT trigger ✅

| Query | Would trigger? |
|---|---|
| "Write Terraform for Azure VMs" | ❌ Excluded: "NOT for Terraform" |
| "Pulumi Azure storage" | ❌ Excluded: "NOT for Pulumi" |
| "AWS CloudFormation template" | ❌ Excluded: "NOT for AWS CloudFormation" |
| "Azure CLI script to create a VM" | ❌ Excluded: "NOT for Azure CLI scripting without IaC" |
| "Write ARM JSON template from scratch" | ❌ Excluded: "NOT for plain ARM JSON authoring" |

### Edge Cases ⚠️

| Query | Concern |
|---|---|
| "Azure deployment troubleshooting" | May false-positive on "Azure deployment" when user means general Azure ops, not IaC |
| "ARM template syntax help" | Could trigger despite user wanting ARM JSON, not Bicep — mitigated by negative trigger for "plain ARM JSON authoring" |

---

## D. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 / 5 | All syntax verified correct. Minor: `bicep test` presented as stable (it's experimental); Storage API version 2 years behind; SQL uses preview API. |
| **Completeness** | 5 / 5 | Exhaustive coverage: every major Bicep feature, 3 deep references, 3 scripts, 5 assets. Missing nothing material. |
| **Actionability** | 5 / 5 | Every concept backed by runnable code. Scripts are production-ready. Pipeline is copy-paste deployable. Asset templates are complete and deployable. |
| **Trigger Quality** | 4 / 5 | Strong positive and negative triggers. Minor: "Azure deployment" slightly broad; "ARM template" edge case. |
| **Overall** | **4.5 / 5** | High-quality skill with minor version currency and trigger precision issues. |

---

## Recommendations (non-blocking)

1. **Update Storage API version** from `2023-05-01` to `2024-01-01` or `2025-06-01` across SKILL.md and assets.
2. **Mark `bicep test` as experimental** in the CLI and Testing sections.
3. **Consider narrowing** "Azure deployment" trigger to "Azure Bicep deployment" or "Azure IaC deployment" to reduce false positives.
4. **Use stable SQL API versions** (e.g., `2023-05-01`) instead of preview (`2023-08-01-preview`) in production examples.
5. **Add a note** that extensibility features (Kubernetes/Graph providers) require `experimentalFeaturesEnabled` in `bicepconfig.json` — this IS noted in advanced-patterns.md but not in SKILL.md body.

---

**Result: PASS** — Overall 4.5/5, no dimension ≤ 2, no blocking issues found.
