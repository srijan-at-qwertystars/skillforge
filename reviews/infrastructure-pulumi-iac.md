# Review: pulumi-iac

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **Old-style S3 Bucket versioning syntax (minor accuracy)**: SKILL.md lines 60–62 use `new aws.s3.Bucket("data-bucket", { versioning: { enabled: true } })` which is the deprecated `aws.s3.Bucket` resource with inline versioning. The modern Pulumi AWS provider (v6+) recommends `aws.s3.BucketV2` + separate `aws.s3.BucketVersioning` resource. The old API still works but is deprecated and will be consolidated in v7. The scaffold script's static-site template correctly uses `BucketV2` — this inconsistency could confuse users. Same issue with the Python example on line 84 using `BucketVersioningArgs`.

2. **Missing `--yes` flag mention for `pulumi new` in CI**: Line 33 mentions `--name`, `--description`, `--stack` to skip prompts but omits `--yes`/`-y` which is needed for fully non-interactive operation. The `pulumi up` CI section correctly shows `--yes` but the `pulumi new` section does not.

3. **Trigger description could include "deploy" verb**: Queries like "deploy cloud infrastructure with TypeScript" or "deploy to AWS with code" might not strongly match the current description since "deploy" isn't explicitly listed as a trigger keyword. Also missing explicit mention of Pulumi YAML programs.

## Structure Check
- ✅ YAML frontmatter has name + description
- ✅ Description has positive AND negative triggers (9 positive, 7 negative)
- ✅ Body is 481 lines (under 500 limit)
- ✅ Imperative voice throughout ("Install the Pulumi CLI", "Create a new project", "Use...")
- ✅ Code examples with TypeScript + Python snippets, CLI commands
- ✅ All references linked and exist (3 reference docs, 3 scripts, 4 assets)

## Content Check
- ✅ CLI commands verified correct: `pulumi new`, `up`, `preview`, `destroy`, `import`, `config set`, `stack init`, `login`, `refresh`, `cancel`
- ✅ `pulumi/actions@v6` confirmed as current latest (v6.6.1)
- ✅ Automation API `LocalWorkspace.createOrSelectStack()` pattern verified correct
- ✅ CrossGuard `validateResourceOfType` API verified correct
- ✅ `StackReference`, `ComponentResource`, dynamic providers — all accurate
- ✅ State backends (S3, Azure Blob, GCS, local) — correct syntax
- ✅ Secrets providers (AWS KMS, Azure KV, GCP KMS, Vault) — correct
- ⚠️ S3 Bucket API uses deprecated pattern (see issue #1)
- ✅ Scripts are well-structured with proper error handling, validation, help text
- ✅ Asset templates are production-quality (OIDC auth, concurrency groups, env protection)

## Trigger Check
- ✅ Strong positive triggers covering 9 distinct use cases
- ✅ Negative triggers exclude 7 competing IaC tools clearly
- ✅ Would trigger for common queries: "Pulumi AWS", "infrastructure as code TypeScript", "import cloud resources Pulumi"
- ✅ Would NOT false-trigger for Terraform, CloudFormation, CDK, Ansible
- ⚠️ Could miss "deploy infrastructure" queries (see issue #3)

## Verdict
Excellent skill. Comprehensive coverage of Pulumi across all major dimensions — setup, core concepts, advanced patterns, CI/CD, troubleshooting. The three reference docs provide deep-dive material. Scripts and assets are production-ready. Minor issues with deprecated S3 API patterns and a small trigger gap do not significantly impact usability. An AI agent would execute very well from this skill.
