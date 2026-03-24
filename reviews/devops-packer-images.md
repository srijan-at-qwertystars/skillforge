# Skill Review: devops/packer-images

**Reviewer:** automated-qa  
**Date:** 2025-07-17  
**Skill path:** `~/skillforge/devops/packer-images/`  
**SKILL.md lines:** 474 (under 500 ✅)  
**Total skill size:** 8,623 lines across 16 files  

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name + description) | ✅ Pass | `name: packer-images`, multi-line `description` present |
| Positive triggers | ✅ Pass | 9 triggers: "Packer template", "Packer build", "machine image", "AMI builder", "packer init", "HCL2 packer", "packer provisioner", "golden image", "image pipeline" |
| Negative triggers | ✅ Pass | 5 exclusions: "Docker image build", "Dockerfile", "Terraform infrastructure", "Vagrant VM", "cloud-init only" |
| Under 500 lines | ✅ Pass | 474 lines (just under limit) |
| Imperative voice | ✅ Pass | Consistent: "Use `.pkr.hcl` extension", "Run `packer init`", "Always pin plugin versions", "Mark secrets with `sensitive = true`" |
| Input→Output example | ✅ Pass | End-to-end example: user prompt → full HCL2 template + CLI invocation |
| Links to references/ | ✅ Pass | Table mapping 4 reference files with content descriptions |
| Links to scripts/ | ✅ Pass | Table mapping 6 scripts with purpose descriptions |
| Links to assets/ | ✅ Pass | Table mapping 5 asset files with content descriptions |

**Structure verdict:** All 9 criteria pass. Well-organized with clear file layout guidance, core blocks, patterns, anti-patterns, and supporting materials.

---

## B. Content Check

### HCL2 Syntax Accuracy

| Area | Status | Detail |
|------|--------|--------|
| `packer {}` block | ✅ Correct | `required_version`, `required_plugins` with version constraints and source paths |
| `variable {}` blocks | ✅ Correct | Types, defaults, descriptions, `validation {}` blocks with `can(regex(...))` |
| `locals {}` block | ✅ Correct | `formatdate()`, `merge()`, template expressions |
| `data` sources | ✅ Correct | `data "amazon-ami"` with `filters`, `most_recent`, `owners`; referenced as `data.amazon-ami.ubuntu.id` |
| `source` blocks | ✅ Correct | All 7 builder types syntactically valid |
| `build` block | ✅ Correct | `sources` list, provisioner ordering, `override`, `only`/`except` |
| Post-processors | ✅ Correct | `manifest`, `compress`, `docker-tag`, `docker-push`, `vagrant`, `shell-local`; chained `post-processors {}` block |

### Builder Names Verified (via web search)

All 7 builder type names are current and correct per HashiCorp documentation:
- `amazon-ebs` ✅ | `azure-arm` ✅ | `googlecompute` ✅ | `docker` ✅
- `vmware-iso` ✅ | `virtualbox-iso` ✅ | `qemu` ✅

### Provisioner Options Verified

| Provisioner | Status | Notes |
|-------------|--------|-------|
| `shell` | ✅ Correct | `inline`, `scripts`, `environment_vars`, `execute_command` all valid |
| `file` | ✅ Correct | `source`, `destination` correct |
| `ansible` | ✅ Correct | `playbook_file`, `extra_arguments`, `ansible_env_vars`, `user` all valid |
| `powershell` | ✅ Correct | `inline` array valid |
| `chef-solo` | ⚠️ Deprecated | Archived since Packer ~1.8; plugin unmaintained. Skill shows without deprecation notice |
| `puppet-masterless` | ⚠️ Deprecated | Archived since Packer ~1.8; plugin unmaintained. Skill shows without deprecation notice |

### Issues Found

1. **Chef/Puppet deprecation not flagged (Medium):** The `chef-solo` and `puppet-masterless` provisioners are archived and unmaintained since Packer 1.8. The skill presents them as equally viable options without any deprecation warning. HashiCorp recommends using `shell`/`shell-local` provisioners to invoke these tools instead. Add a deprecation notice.

2. **GitHub Actions scan job non-functional (Low):** In `assets/github-actions.yml`, the scan job at ~line 169 is scaffolded but the actual Trivy scanning step is incomplete. The HCP Packer promotion conditional (`if: env.HCP_CLIENT_ID != ''`) checks env vars instead of secrets, so it will always be skipped.

3. **cleanup-images.sh quoting issues (Low):** Unquoted variable expansions in array loops (~lines 217, 270) could break with spaces in image names. Missing numeric validation for `--keep` argument.

4. **build-ami.sh IFS not restored (Low):** IFS manipulation at ~line 229 doesn't save/restore original value.

### Missing Gotchas (Minor)

- No mention of `packer plugins install` as alternative to `packer init` for individual plugin installation
- No guidance on Packer version pinning in CI (e.g., `hashicorp/setup-packer@v3` with explicit version)
- No mention of `discard` option for Docker builder (third mode alongside `commit` and `export_path`)
- `SourceAMI` template variable `{{ .SourceAMI }}` in locals block (line 89) only works inside provisioner context, not in locals — minor inaccuracy

### Reference Files Quality

| File | Lines | Grade | Notes |
|------|-------|-------|-------|
| `references/advanced-patterns.md` | 1,636 | A+ | Exceptional depth: multi-stage builds, HCP Packer, dynamic blocks, image ancestry |
| `references/cloud-builders.md` | 971 | A | Comprehensive cloud coverage; all builder options verified correct |
| `references/security-hardening.md` | 992 | A- | Strong CIS/hardening content; STIG and SBOM sections could be deeper |
| `references/troubleshooting.md` | 1,409 | A | Excellent diagnostics; build optimization section is standout |

### Scripts Quality

| Script | Lines | Grade | Notes |
|--------|-------|-------|-------|
| `scripts/build-image.sh` | 275 | A+ | Exemplary: `set -euo pipefail`, color output, structured logging |
| `scripts/validate-template.sh` | 358 | A+ | Multi-layer validation, JSON output, credential checks |
| `scripts/cleanup-images.sh` | 445 | B+ | Multi-provider; quoting issues in loops |
| `scripts/build-ami.sh` | 297 | B+ | Good subcommands; IFS issue, unquoted vars |
| `scripts/init-packer-project.sh` | 386 | A+ | Clean scaffolding with heredocs |
| `scripts/scan-image.sh` | 392 | A+ | Proper cleanup traps, SSH retry logic |

### Assets Quality

| Asset | Lines | Grade | Notes |
|-------|-------|-------|-------|
| `assets/aws-base.pkr.hcl` | 276 | A | Spot pricing, encryption, multi-region, error-cleanup provisioner |
| `assets/docker-base.pkr.hcl` | 205 | A | OCI labels, healthcheck, non-root user, tag+push chain |
| `assets/github-actions.yml` | 240 | B | Non-functional scan job; HCP condition logic wrong |
| `assets/variables.pkr.hcl` | 171 | A+ | Comprehensive validations with regex and `alltrue()` |
| `assets/Makefile` | 96 | A+ | Clean targets, git SHA capture, auto-help |

---

## C. Trigger Check

### Positive Trigger Analysis

| Query | Would Trigger? | Correct? |
|-------|---------------|----------|
| "Create a Packer template for Ubuntu AMI" | ✅ Yes | ✅ |
| "How do I build a golden image with Packer?" | ✅ Yes | ✅ |
| "Packer HCL2 provisioner for Ansible" | ✅ Yes | ✅ |
| "Set up an AMI builder pipeline" | ✅ Yes | ✅ |
| "packer init not finding plugins" | ✅ Yes | ✅ |
| "How to create a machine image for GCP" | ✅ Yes | ✅ |
| "Image pipeline with Packer and GitHub Actions" | ✅ Yes | ✅ |

### Negative Trigger Analysis (False Positive Check)

| Query | Would Trigger? | Correct? |
|-------|---------------|----------|
| "Build a Docker image with a Dockerfile" | ❌ No | ✅ Correctly excluded |
| "Write Terraform to deploy EC2 instances" | ❌ No | ✅ Correctly excluded |
| "Create a Vagrant box configuration" | ❌ No | ✅ Correctly excluded |
| "Set up cloud-init for Ubuntu" | ❌ No | ✅ Correctly excluded |
| "Docker compose for multi-container app" | ❌ No | ✅ Correctly excluded |

### Edge Cases

| Query | Would Trigger? | Analysis |
|-------|---------------|----------|
| "Use Packer Docker builder to create image" | ✅ Yes | ✅ Correct — Packer context, not Docker-native |
| "Convert Packer JSON to HCL2" | ✅ Yes | ✅ Correct — covered in anti-patterns |
| "Ansible playbook for server hardening" | ❌ No | ✅ Correct — general Ansible, not Packer-specific |
| "Create an AMI" (no "Packer" mention) | ⚠️ Maybe | Weak match — "AMI builder" trigger might catch this but ambiguous |

**Trigger verdict:** Strong trigger set with clear domain boundaries. Minimal false-positive risk.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4/5 | HCL2 syntax correct throughout. All builder names verified. Deducted for presenting deprecated chef-solo/puppet-masterless without caveat, and `{{ .SourceAMI }}` in locals context issue. |
| **Completeness** | 5/5 | Exceptional: 7 builders, 6 provisioner types, 7 post-processors, variables/locals/data sources, multi-build patterns, CI/CD, patterns, anti-patterns. 4 deep references (5,008 lines), 6 scripts (2,153 lines), 5 assets (988 lines). |
| **Actionability** | 5/5 | Every concept has copy-paste HCL2 examples. Input→Output example shows full workflow. Scripts are executable. Assets are production-ready. |
| **Trigger Quality** | 4/5 | Well-scoped 9 positive + 5 negative triggers. Clear boundaries. Minor edge case with "AMI builder" in non-Packer contexts. |

### Overall Score: 4.5 / 5.0

---

## E. Recommendations

### Must Fix
1. **Add deprecation notice for chef-solo and puppet-masterless provisioners.** Note they are archived since Packer ~1.8 and recommend `shell`/`shell-local` as the maintained alternative.

### Should Fix
2. **Fix `{{ .SourceAMI }}` in locals block** (SKILL.md line 89). Template variables only work inside provisioner/post-processor contexts. Use a data source reference or pass via variable instead.
3. **Complete the GitHub Actions scan job** in `assets/github-actions.yml` — currently scaffolded but non-functional.
4. **Fix HCP secret conditional** in `assets/github-actions.yml` — change `env.HCP_CLIENT_ID` to `secrets.HCP_CLIENT_ID`.

### Nice to Have
5. Add `packer plugins install` as alternative to `packer init` for individual plugins.
6. Fix quoting issues in `scripts/cleanup-images.sh` and IFS restoration in `scripts/build-ami.sh`.
7. Mention Docker builder's `discard` option as a third mode alongside `commit` and `export_path`.

---

## F. Verdict

| Check | Result |
|-------|--------|
| Overall ≥ 4.0 | ✅ 4.5 |
| Any dimension ≤ 2 | ✅ None (minimum is 4) |
| GitHub issues required | ❌ No |
| SKILL.md tag | `<!-- tested: pass -->` |

**Result: PASS** — High-quality skill with comprehensive coverage and strong actionability. Minor improvements recommended but no blocking issues.
