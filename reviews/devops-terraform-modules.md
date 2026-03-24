# QA Review: devops/terraform-modules

**Skill path:** `devops/terraform-modules/`
**Reviewed:** 2025-07-25 (re-review)
**Previous review:** 2025-07-17
**Reviewer:** Copilot CLI (automated)
**Verdict:** ✅ PASS

---

## Scores

| Dimension | Score | Notes |
|-----------|-------|-------|
| **Accuracy** | 4 / 5 | All version claims verified correct via web search. One factual error: EKS module example uses `enable_irsa` which was removed in v20. |
| **Completeness** | 5 / 5 | Comprehensive coverage across SKILL.md (491 lines) + 3 references (3,758 lines) + 3 scripts + 7 assets. |
| **Actionability** | 5 / 5 | Copy-pasteable HCL examples, ready-to-use scripts, production-grade CI/CD workflows, complete VPC module. |
| **Trigger Quality** | 4 / 5 | Strong positive/negative triggers. Minor false-trigger risk on broad terms. Missing OpenTofu negative trigger. |
| **Overall** | **4.5 / 5** | High-quality skill. One content fix needed. |

---

## a. Structure Check

| Criterion | Status | Detail |
|-----------|--------|--------|
| YAML frontmatter `name` | ✅ | `terraform-modules` |
| YAML frontmatter `description` | ✅ | Multi-line, describes purpose clearly |
| Positive triggers | ✅ | Terraform modules, HCL, IaC, module composition, Registry, state management, remote backends, workspaces, provider config, variable validation, moved/import/removed blocks, terraform test, CI/CD |
| Negative triggers | ✅ | Pulumi, CloudFormation, CDK, Ansible, Chef/Puppet, simple shell scripts |
| Body under 500 lines | ✅ | 491 lines (tight but passes) |
| Imperative voice | ✅ | "Organize every module…", "Declare typed variables…", "Pin versions explicitly…" |
| Examples | ✅ | 15+ HCL code blocks in SKILL.md |
| Resources linked | ✅ | 3 references, 3 scripts, 7 assets — all linked in tables at bottom, all files verified present |

### Full File Inventory

| File | Lines | Status |
|------|-------|--------|
| `SKILL.md` | 491 | ✅ |
| `references/advanced-patterns.md` | 1,393 | ✅ 14 sections |
| `references/troubleshooting.md` | 1,260 | ✅ 13 sections |
| `references/testing-guide.md` | 1,105 | ✅ 5 major sections |
| `scripts/scaffold-module.sh` | 265 | ✅ Generates standard layout |
| `scripts/validate-module.sh` | 178 | ✅ Full validation suite |
| `scripts/publish-module.sh` | 284 | ✅ Semver tagging + registry |
| `assets/vpc-module/{main,variables,outputs}.tf` | 225+69+35 | ✅ Complete VPC module |
| `assets/module-template/{5 files}` | ~150 | ✅ Starter template |
| `assets/github-actions.yml` | 264 | ✅ Full CI/CD pipeline |
| `assets/github-actions-ci.yml` | 190 | ✅ Module CI pipeline |
| `assets/terragrunt.hcl` | 187 | ✅ DRY hierarchy template |
| `assets/terrafile.hcl` | 154 | ✅ Test file examples |
| `assets/.tflint.hcl` | 158 | ✅ TFLint configuration |

---

## b. Content Check

### Version Claims — Web-Search Verified

| Claim in SKILL.md | Stated Version | Verified Version | Status |
|--------------------|---------------|-----------------|--------|
| `terraform test` introduced | 1.6+ | 1.6.0 | ✅ |
| `mock_provider` introduced | 1.7+ | 1.7.0 | ✅ |
| `removed` block introduced | 1.7+ | 1.7.0 | ✅ |
| `import` block introduced | 1.5+ | 1.5.0 | ✅ |
| `optional()` GA | 1.3+ | 1.3.0 | ✅ |

### HCL Syntax Accuracy
- `terraform` block, `variable` blocks, `output` blocks, `module` blocks: ✅ All correct
- `moved` block syntax: ✅ Correct
- Version constraints (`~>`, `>=`): ✅ Correct semantics
- Remote sources (registry, git `?ref=`, S3): ✅ Correct
- Provider aliasing and `configuration_aliases`: ✅ Correct
- `terraform test` `.tftest.hcl` syntax: ✅ Matches Terraform 1.6+ framework

### Issues Found

| # | Severity | Issue | Location |
|---|----------|-------|----------|
| 1 | 🔴 Medium | **EKS example uses `enable_irsa = true`** — this parameter was **removed** in terraform-aws-modules/eks/aws v20. The example specifies `version = "~> 20.0"` but `enable_irsa` does not exist in that version. A user copying this would get a Terraform error. | SKILL.md ~L439 |
| 2 | 🟡 Low | `required_version` inconsistency: SKILL.md example uses `>= 1.5.0` but module template and scaffold script use `>= 1.6.0`. Could confuse readers about which minimum to use. | SKILL.md L36 vs templates |
| 3 | 🟡 Low | Missing OpenTofu in negative triggers — the most common Terraform alternative with compatible syntax. | YAML frontmatter |
| 4 | 🟢 Info | VPC flow logs IAM policy uses `Resource = "*"` — overly permissive. Could scope to log group ARN. | assets/vpc-module/main.tf L207 |
| 5 | 🟢 Info | No mention of `.terraform.lock.hcl` commit strategy in SKILL.md or references. | — |
| 6 | 🟢 Info | No mention of `terraform-docs` tool in main SKILL.md (only in validate script). | SKILL.md |

---

## c. Trigger Check

### Positive Triggers — Would correctly trigger for:
- ✅ "Create a Terraform module for S3"
- ✅ "How do I test my Terraform configuration?"
- ✅ "Set up remote backend with S3 and DynamoDB"
- ✅ "Refactor Terraform resources with moved blocks"
- ✅ "CI/CD pipeline for Terraform"
- ✅ "Terraform variable validation patterns"

### Negative Triggers — Correctly excludes:
- ✅ Pulumi, CloudFormation, CDK, Ansible, Chef/Puppet, simple shell scripts

### False Trigger Risks:
- ⚠️ "infrastructure as code" — broad; could match general IaC discussions
- ⚠️ "CI/CD pipelines for infrastructure" — could match non-Terraform CI/CD
- ⚠️ Missing negative for **OpenTofu** (Terraform fork with compatible syntax)
- ⚠️ Missing negative for **Crossplane** (Kubernetes-native IaC)

---

## d. Score Justification

**Accuracy (4/5):** All five Terraform version claims independently verified correct. The `enable_irsa` error in the EKS v20 example is the only factual issue — it would cause a real Terraform error for users.

**Completeness (5/5):** Exceptionally thorough. SKILL.md covers module structure, design principles, variables, outputs, sources, versioning, composition, state management, import blocks, workspaces, testing (native + Terratest), CI/CD, provider configuration, data sources, dynamic blocks, moved/removed blocks, and common patterns. Three reference documents add 3,758 lines of advanced patterns, troubleshooting, and testing guidance. Assets include runnable examples.

**Actionability (5/5):** Every section has copy-pasteable code. Scaffold script generates a working module skeleton. Validate script runs a full CI suite. GitHub Actions workflows are production-ready. VPC module is deployable. Users can go from zero to a tested, published module.

**Trigger Quality (4/5):** Strong coverage of Terraform-specific terms with clear negative triggers. Minor over-triggering risk on broad IaC/CI terms. The OpenTofu omission is the most notable gap.

---

## e. Recommendations (non-blocking)

1. **Fix EKS example**: Remove `enable_irsa = true` from the EKS v20 example or add a comment that IRSA is managed differently in v20+
2. **Align `required_version`**: Standardize on `>= 1.6.0` across all examples since `terraform test` requires it
3. **Add OpenTofu negative trigger**: "Do NOT use for … OpenTofu (unless discussing Terraform compatibility)"
4. **Scope VPC flow logs IAM**: Replace `Resource = "*"` with the specific log group ARN

## f. GitHub Issues

No issues filed — overall score 4.5 ≥ 4.0 and no dimension ≤ 2.

## g. Test Marker

`<!-- tested: pass -->` appended to SKILL.md.
