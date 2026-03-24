# Review: aws-cdk

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **`pointInTimeRecoveryEnabled` → `pointInTimeRecovery`** (fixed): Line 186 used `pointInTimeRecoveryEnabled: true` on the L2 `dynamodb.Table` construct. The correct property name is `pointInTimeRecovery`. `pointInTimeRecoveryEnabled` belongs to the L1 `CfnTable` under `pointInTimeRecoverySpecification`. Fixed in this review pass.

2. **Minor: `lambda_nodejs.OutputFormat.ESM` reference** (not fixed, acceptable): The Asset Bundling snippet references `lambda_nodejs.OutputFormat.ESM` but the import shown is `import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs'`, not a namespace import. The enum exists and is correct, but the snippet isn't self-contained. Acceptable for a reference snippet.

## Structure Check

| Criterion | Status |
|-----------|--------|
| YAML frontmatter `name` + `description` | ✅ |
| Positive triggers (TRIGGER when) | ✅ Detailed: CDK stacks, constructs, IaC, specific CLI commands, L1/L2/L3, patterns, Pipelines, cdk-nag |
| Negative triggers (DO NOT TRIGGER when) | ✅ Terraform, Pulumi, CloudFormation YAML/JSON, SAM, Serverless Framework, non-AWS |
| Body under 500 lines | ✅ 499 lines |
| Imperative voice, no filler | ✅ Concise throughout |
| Examples with input/output | ✅ Two I/O examples at end |
| references/ linked from SKILL.md | ✅ Table with 3 docs |
| scripts/ linked from SKILL.md | ✅ Table with 3 scripts |
| assets/ linked from SKILL.md | ✅ Table with 5 templates |

## Content Verification

| Item | Status | Notes |
|------|--------|-------|
| `cdk init` | ✅ | Correct: `npx cdk init app --language typescript` |
| `cdk synth` | ✅ | Correct usage and description |
| `cdk diff` | ✅ | Correct; `--strict` flag documented |
| `cdk deploy` | ✅ | Correct; `--hotswap`, `--require-approval`, `--exclusively` documented |
| `cdk destroy` | ✅ | Correct |
| `cdk bootstrap` | ✅ | Correct including cross-account `--trust` pattern |
| `cdk watch`, `cdk ls`, `cdk doctor` | ✅ | All correct |
| L1/L2/L3 construct descriptions | ✅ | Accurate taxonomy |
| Lambda + API Gateway (TS & Python) | ✅ | Correct imports, class names, API |
| S3 + CloudFront with OAC | ✅ | Uses modern `S3BucketOrigin.withOriginAccessControl()` — current best practice |
| VPC + ECS Fargate | ✅ | `ApplicationLoadBalancedFargateService` correct |
| DynamoDB + SQS/SNS | ✅ | Correct (after PITR fix) |
| CDK Pipelines API | ✅ | Uses modern `CodePipeline` from `aws-cdk-lib/pipelines`, not deprecated `CdkPipeline` |
| `ManualApprovalStep` | ✅ | Correct API |
| `CodePipelineSource.gitHub` | ✅ | Correct |
| cdk-nag `AwsSolutionsChecks` | ✅ | Correct class name and import |
| cdk-nag `HIPAASecurityChecks` | ✅ | Correct |
| cdk-nag `NIST80053R5Checks` | ✅ | Correct |
| `NagSuppressions.addStackSuppressions` | ✅ | Correct API |
| `NagSuppressions.addResourceSuppressions` | ✅ | Correct (in references) |
| Custom Aspects (`IAspect`) | ✅ | Correct interface and `visit` method |
| Escape hatches (`addPropertyOverride`) | ✅ | Correct (in references) |
| CDK Migrate | ✅ | Correct `--from-path`, `--from-stack` flags |
| `cdk import` | ✅ | Correct |
| Testing (`Template.fromStack`, `hasResourceProperties`) | ✅ | Correct assertions API |
| Snapshot testing | ✅ | Correct pattern |
| jsii construct library | ✅ | Correct constraints and workflow |

## Gotchas Coverage

| Gotcha | Covered? |
|--------|----------|
| Circular dependencies | ✅ SKILL.md #1 + troubleshooting ref |
| Removal policy defaults | ✅ SKILL.md #2 + best practices |
| Physical names prevent replacement | ✅ SKILL.md #3 |
| Cross-stack export locks | ✅ SKILL.md #4 |
| Token resolution | ✅ SKILL.md #7 + troubleshooting ref |
| Construct ID uniqueness | ✅ SKILL.md #6 |
| Bootstrap version mismatches | ✅ Troubleshooting reference |
| `cdk.context.json` must be committed | ✅ Advanced patterns ref |
| Docker/esbuild bundling issues | ✅ Troubleshooting reference |
| Stack rollback handling | ✅ Troubleshooting reference |

## Trigger Check

- **CDK queries**: Would trigger ✅ — description covers CDK stacks, constructs, CLI commands, specific AWS patterns
- **CloudFormation YAML/JSON**: Would NOT trigger ✅ — explicitly excluded
- **Terraform**: Would NOT trigger ✅ — explicitly excluded
- **Pulumi**: Would NOT trigger ✅ — explicitly excluded
- **SAM / Serverless Framework**: Would NOT trigger ✅ — explicitly excluded
- **Description specificity**: Excellent — lists exact commands and pattern names

## Supporting Files Quality

- **references/**: 3 comprehensive docs (advanced-patterns 675 lines, troubleshooting 590 lines, construct-library 723 lines) — thorough
- **scripts/**: 3 executable bash scripts with argument parsing, validation, and help — production quality
- **assets/**: 5 templates (stack, construct, pipeline, cdk-nag, Makefile) — copy-paste ready, well-documented

## Verdict

Excellent skill. Comprehensive coverage of AWS CDK v2 with accurate, current APIs. One property name error found and fixed. All supporting files are high quality and properly linked. Trigger description is precise with clear inclusion/exclusion criteria.
