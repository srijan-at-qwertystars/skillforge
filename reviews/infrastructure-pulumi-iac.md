# Review: pulumi-iac

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:
- **S3 locking misleading (Accuracy)**: State Backends table claims `s3://bucket?region=us-east-1&awssdk=v2` provides "Concurrent access safety", but `awssdk=v2` alone does NOT enable locking. Actual locking requires `&dynamodbTable=<table-name>` query parameter. Without it, concurrent access is still unsafe.
- **`pulumi import --out` takes a directory, not a file**: Line 403 uses `--out index.ts` implying a file, but `--out` expects a directory path per Pulumi docs.
- **Two unlisted assets**: `Pulumi.yaml` and `github-actions-pulumi.yml` exist in `assets/` but are not documented in the SKILL.md assets table.
- **Minor**: Dynamic providers note says "pnpm or Bun runtimes" — Bun as a *package manager* works fine; only Bun as a *runtime* is incompatible. The statement is defensible but slightly imprecise.

## Structure Check
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive triggers (9 use cases) AND negative triggers (7 exclusions)
- ✅ Body is 499 lines (under 500 limit)
- ✅ Imperative voice throughout, no filler
- ✅ Multiple examples with input/output across TypeScript, Python, Go
- ✅ references/ and scripts/ properly linked from SKILL.md tables

## Content Check
- ✅ CLI commands verified correct: `pulumi new`, `up`, `preview`, `destroy`, `import`, `config set`, `stack init`, `login`, `refresh`, `cancel`, `watch`, `convert`
- ✅ `pulumi/actions@v6` confirmed as current latest version
- ✅ `registerResourceTransform` API syntax verified correct
- ✅ Automation API `LocalWorkspace.createOrSelectStack()` pattern verified
- ✅ CrossGuard `validateResourceOfType` API verified
- ✅ Dynamic providers pnpm/Bun incompatibility confirmed by Pulumi docs
- ✅ State backends (S3, Azure Blob, GCS, local) — correct syntax
- ✅ Secrets providers (AWS KMS, Azure KV, GCP KMS, passphrase) — correct
- ⚠️ S3 locking claim misleading (see issue above)
- ⚠️ `--out` parameter usage incorrect (see issue above)
- ✅ Scripts (5) are well-structured with proper error handling, validation, help text
- ✅ Asset templates (7) are production-quality (OIDC auth, concurrency groups, env protection)
- ✅ Reference docs (4) total ~190KB of dense, searchable advanced content

## Trigger Check
- ✅ Strong positive triggers: Pulumi projects, IaC with TS/Python/Go/C#/Java/YAML, cloud provisioning, stack management, Automation API, component resources, config/secrets, CrossGuard, importing
- ✅ Clear negative triggers: Terraform/HCL/OpenTofu, CloudFormation, CDK, Ansible, Chef/Puppet, pure K8s manifests, unrelated Docker
- ✅ Would NOT false-trigger on competing IaC tools
- ✅ Specific enough for real-world Pulumi queries

## Verdict
Excellent skill. PASS. Comprehensive coverage of all major Pulumi dimensions with production-quality scripts and templates. Minor accuracy issues (S3 locking, import --out) do not materially impair usability. An AI agent would execute very well from this skill alone.
