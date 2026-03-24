# QA Review: pulumi-iac

**Skill path:** `devops/pulumi-iac/`  
**Reviewer:** Copilot QA  
**Date:** 2025-07-17

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `pulumi-iac` |
| YAML frontmatter `description` | ✅ | Present with positive triggers (Pulumi files, SDK imports, CLI commands, ESC, Automation API) |
| Negative triggers | ✅ | Explicitly excludes Terraform, CloudFormation, CDK, Ansible, Chef/Puppet |
| Body ≤ 500 lines | ✅ | Exactly 500 lines |
| Imperative voice | ✅ | Uses direct instructions ("Use", "Pass", "Never call") |
| No filler | ✅ | Dense, no fluff |
| Examples with I/O | ✅ | CLI examples with commands and expected usage; code examples with exports |
| Links to refs/scripts | ✅ | Links to all 3 references, 3 scripts, 4 assets |

**Structure issues found:**
- **Unclosed Go code block** (line 116–131): The Go example starting with ` ```go ` is missing its closing ` ``` ` fence. This causes markdown renderers to swallow "## Core Concepts" and subsequent content into the code block.

---

## b. Content Check — Technical Accuracy

### CLI Commands — ✅ Correct
All CLI commands verified against official Pulumi docs:
- `pulumi new <template>`, `pulumi up`, `pulumi preview`, `pulumi stack init/select/ls`, `pulumi config set/get`, `pulumi login`, `pulumi import`, `pulumi refresh`, `pulumi destroy` — all correct syntax.
- `pulumi preview --expect-no-changes`, `--policy-pack`, `--parallel` flags — correct.
- `pulumi stack export/import`, `pulumi state delete`, `pulumi cancel` — correct.

### SDK APIs — ✅ Mostly Correct
- `Output<T>`, `Input<T>`, `.apply()`, `pulumi.interpolate`, `pulumi.all()` — correct usage.
- `ComponentResource` pattern with `super()`, `{ parent: this }`, `this.registerOutputs()` — correct.
- `pulumi.Config`, `config.require()`, `config.requireSecret()`, `config.get()` — correct.
- `StackReference`, `getOutput()`, `requireOutput()` — correct.
- `pulumi.dynamic.ResourceProvider` and `pulumi.dynamic.Resource` — correct pattern.

### Provider Patterns — ⚠️ Minor Issues
1. **S3 Bucket versioning (TypeScript, line 60):** Uses `versioning: { enabled: true }` directly on `aws.s3.Bucket`. This inline `versioning` property is **deprecated** in AWS provider v6+ and will be removed in v7. Best practice is to use `aws.s3.BucketVersioningV2` as a separate resource. The skill should note this deprecation.
2. **S3 Bucket versioning (Python, line 106):** Same issue — `versioning=aws.s3.BucketVersioningArgs(enabled=True)` uses the deprecated inline property.
3. **Dynamic providers limitation (line 220):** States "TypeScript/JavaScript only." This is **inaccurate** — dynamic providers are supported in **TypeScript/JavaScript AND Python**. Go and other languages do not support them.

### Factual Claims — ⚠️ Minor Issues
4. **Provider count (line 451):** States "150+" Pulumi providers vs Terraform's "3000+". The Pulumi Registry now lists ~296 packages. The "150+" figure is outdated.
5. **`registerStackTransformation` (advanced-patterns.md, line 230):** Uses `pulumi.runtime.registerStackTransformation()` which is **deprecated** in favor of `pulumi.runtime.registerResourceTransformation()` / `transformations` resource option.

### Testing Patterns — ✅ Correct
- `pulumi.runtime.setMocks()` with `newResource`/`call` — correct API.
- Python `pulumi.runtime.Mocks` class and `@pulumi.runtime.test` decorator — correct.
- Automation API integration test pattern with `LocalWorkspace.createOrSelectStack` — correct.

### Missing Gotchas
6. **No mention of `pulumi convert --from terraform`** migration gotchas (partial conversion, manual fixup needed).
7. **No mention of state locking** details (S3+DynamoDB for self-managed backends). Troubleshooting doc covers this partially.
8. **`--out` flag on `pulumi import`** (line 375) with `--out index.ts` is correct but `--generate-code` in troubleshooting.md (line 150) is redundant — `--out` implies code generation.

---

## c. Trigger Check

| Scenario | Expected | Actual | Status |
|----------|----------|--------|--------|
| User writes `@pulumi/aws` TypeScript | Trigger | ✅ Triggers (SDK imports) |
| User runs `pulumi up` | Trigger | ✅ Triggers (CLI commands) |
| User edits `Pulumi.yaml` | Trigger | ✅ Triggers (Pulumi project files) |
| User writes Terraform HCL | No trigger | ✅ Excluded |
| User writes CloudFormation YAML | No trigger | ✅ Excluded |
| User writes AWS CDK constructs | No trigger | ✅ Excluded |
| User runs `aws s3 ls` (no Pulumi context) | No trigger | ✅ Excluded |
| User mentions "infrastructure as code" generically | No trigger | ✅ Not triggered (requires Pulumi context) |
| User writes Ansible playbook | No trigger | ✅ Excluded |

Triggers are well-scoped. No false positive risk identified.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | CLI and SDK APIs correct. Minor inaccuracies: dynamic provider language support, deprecated S3 versioning pattern, outdated provider count, deprecated `registerStackTransformation`. |
| **Completeness** | 4 | Excellent coverage: 4 languages, providers, testing, CI/CD, ESC, CrossGuard, import, Automation API. Missing: Pulumi Deployments, `pulumi watch`, newer transforms API. |
| **Actionability** | 5 | Immediately usable code examples, copy-paste scripts, production-grade templates, troubleshooting decision trees. |
| **Trigger Quality** | 5 | Precise positive/negative triggers, no false positive risk, covers CLI commands and SDK patterns. |

**Overall: 4.5 / 5.0**

---

## e. Issues

No GitHub issues required (overall ≥ 4.0, no dimension ≤ 2).

---

## f. Recommended Fixes (non-blocking)

1. **Fix unclosed Go code block** — Add closing ` ``` ` after line 131 in SKILL.md.
2. **Update dynamic provider language support** — Change "TypeScript/JavaScript only" to "TypeScript/JavaScript and Python" (line 220 of advanced-patterns.md).
3. **Add deprecation note for S3 `versioning` inline property** — Recommend `BucketVersioningV2` as separate resource for AWS provider v6+.
4. **Update provider count** — Change "150+" to "~200+" or "200+" to be more accurate.
5. **Update `registerStackTransformation`** to `registerResourceTransformation` in advanced-patterns.md.

---

**Result: PASS** ✅
