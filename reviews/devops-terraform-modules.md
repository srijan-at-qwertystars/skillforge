# QA Review: terraform-modules

**Skill path:** `devops/terraform-modules/`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | `name`, `description` with positive + negative triggers present |
| Under 500 lines | ✅ | Exactly 500 lines (at the limit but passes) |
| Imperative voice | ✅ | "Use the canonical layout", "Pin everything", "Define in variables.tf", "Never declare provider blocks inside child modules" |
| Examples | ✅ | 3 worked examples: reusable VPC module, terraform test, multi-region provider aliases |
| References linked | ✅ | 3 reference files (advanced-patterns, troubleshooting, testing-guide); all exist, 960-1100 lines each — substantial depth |
| Scripts linked | ✅ | 3 scripts (scaffold-module.sh, validate-module.sh, publish-module.sh); all exist, well-documented with usage headers |
| Assets linked | ✅ | 4 assets (module-template/, github-actions-ci.yml, terrafile.hcl, .tflint.hcl); all present and functional |

## b. Content Check

### HCL Syntax Accuracy
- **`terraform` block** (`required_version`, `required_providers`): ✅ Correct
- **`variable` blocks** (type, description, validation, sensitive, optional): ✅ Correct; `optional()` syntax matches Terraform 1.3+
- **`output` blocks** (value, sensitive, description): ✅ Correct
- **`module` blocks** (source, version, for_each, providers): ✅ Correct
- **`moved` block**: ✅ Correct syntax (`from`/`to` use unquoted addresses, matching Terraform docs)
- **Version constraints** (`~>`, `>=`, exact): ✅ Correct semantics
- **Remote sources** (registry, git `?ref=`, S3): ✅ Correct format
- **Provider aliasing** and `configuration_aliases`: ✅ Correct pattern — child declares aliases, root maps via `providers = {}`
- **`terraform test`** (`.tftest.hcl`): ✅ Syntax matches official Terraform 1.6+ framework — `variables`, `run`, `command`, `assert`, `expect_failures` all verified

### Module Patterns
- Flat composition, facade, for_each stamping: ✅ All standard patterns correctly demonstrated
- Remote state cross-reference: ✅ Correct with appropriate caveat ("prefer passing outputs explicitly")
- Workspace management: ✅ Functional pattern using `terraform.workspace`

### CI/CD & Tooling
- GitHub Actions workflow: ✅ Uses `hashicorp/setup-terraform@v3`, `actions/checkout@v4`; includes OIDC for AWS — production-ready
- Static analysis pipeline (`fmt -check`, `validate`, `tflint`, `checkov`, `trivy`): ✅ Correct
- Terratest Go example: ✅ Correct pattern (`InitAndApply`, `Destroy`, `Output`)
- Semver tagging: ✅ Correct workflow

### Missing Gotchas (minor)
1. **`import` block** (Terraform 1.5+): Listed in triggers but no section in main SKILL.md. Covered in `references/advanced-patterns.md` but a brief mention in the main doc would improve discoverability.
2. **`removed` block** (Terraform 1.7+): Not mentioned in SKILL.md. Covered in references.
3. **`count` index shifting pitfall**: The main doc uses `for_each` examples well but doesn't explicitly warn about `count` index instability. Covered in `references/troubleshooting.md`.
4. **`for_each` values must be known at plan time**: Not mentioned in main doc. Covered in troubleshooting reference.
5. **Workspace caveat**: The workspace section doesn't note HashiCorp's recommendation to prefer separate directories/backends over workspaces for production environments.

All five gaps are covered in the reference files, so the overall package is complete. Main SKILL.md could surface items 1 and 3 for better standalone usability.

## c. Trigger Check

### Positive Triggers
| Trigger | Specific to modules? | Risk |
|---------|---------------------|------|
| "terraform module", "tf module composition" | ✅ Highly specific | Low |
| "terraform registry", "module versioning" | ✅ Module-specific | Low |
| "module inputs outputs", "terraform remote module" | ✅ Module-specific | Low |
| "HCL module pattern" | ✅ Module-specific | Low |
| "terraform test", "terratest" | ⚠️ Could be general TF testing | Low-medium |
| "terraform workspaces" | ⚠️ Could be general workspace Q | Medium |
| "terraform state management" | ⚠️ Broad — not always module-related | Medium |
| "terraform troubleshooting" | ⚠️ Broad — any TF problem | Medium |
| "terraform import", "terraform moved block" | ⚠️ Could be standalone ops | Low-medium |
| "tflint", "tfsec", "checkov" | ⚠️ Tools used beyond modules | Medium |
| "terraform CI/CD" | ⚠️ Could be general pipeline Q | Low-medium |
| "terraform provider configuration" | ⚠️ Could be root-only config | Low-medium |

### Negative Triggers
✅ Correctly excludes: Pulumi, CloudFormation, CDK, Ansible, general cloud questions.

### False Trigger Assessment
- **Pulumi/CloudFormation**: ❌ Will NOT falsely trigger — negative triggers prevent this
- **General Terraform usage** (e.g., "how do I write a resource block"): ❌ Will NOT trigger — none of the positive triggers match basic usage
- **Broad triggers** ("terraform troubleshooting", "terraform state management", "tflint"): ⚠️ COULD trigger for non-module Terraform questions. The content is still useful in those contexts, so this is a minor concern rather than a defect.

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All HCL syntax verified correct against official docs. Provider aliasing, terraform test, moved blocks, version constraints — all accurate. |
| **Completeness** | 4 | Excellent breadth: module structure, variables, outputs, composition, versioning, testing, CI/CD, registry, state. Minor gaps in main doc (import block, removed block, count pitfall) are covered in references. |
| **Actionability** | 5 | Copy-paste ready code blocks. Three automation scripts (scaffold, validate, publish). Complete CI/CD template. Practical examples with real-world patterns. |
| **Trigger quality** | 4 | 19 positive triggers are comprehensive. Negative triggers are correct. A few triggers are broad ("terraform troubleshooting", "tflint") but unlikely to cause real problems. |

**Overall: 4.5 / 5** — ✅ PASS

## e. Recommendations (non-blocking)

1. Add a brief `import` block section to SKILL.md (2-3 lines + example) since it's listed in triggers
2. Add a one-line warning about `count` index instability in the composition section
3. Consider narrowing "terraform troubleshooting" to "terraform module troubleshooting" in triggers
4. Consider adding "terraform removed block" to triggers since it's covered in references
5. SKILL.md is at exactly 500 lines — any additions would require trimming elsewhere

## f. GitHub Issues

No issues filed — overall score 4.5 ≥ 4.0 and no dimension ≤ 2.

## g. Test Marker

`<!-- tested: pass -->` appended to SKILL.md.
