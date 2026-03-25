# QA Review: serverless-framework

**Skill path:** `~/skillforge/cloud/serverless-framework/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** ✅ PASS

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ | `serverless-framework` |
| YAML frontmatter `description` | ✅ | Detailed, multi-sentence |
| Positive triggers | ✅ | 12+ specific trigger scenarios (serverless.yml, Lambda, API Gateway, event sources, plugins, packaging, layers, CloudFormation, stages, Dashboard, CI/CD) |
| Negative triggers | ✅ | 6 explicit exclusions (SAM, Terraform, Pulumi, CDK, Vercel/Netlify, K8s/ECS/EKS/Fargate, general CloudFormation) |
| Body under 500 lines | ✅ | 452 lines |
| Imperative voice | ✅ | "Key Rules" section uses imperative throughout ("Use…", "Set…", "Prefer…", "Never…") |
| Examples | ✅ | Extensive: 20+ YAML/bash code blocks covering every event type, packaging, IAM, VPC, plugins, stages, variables, resources, CI/CD |
| References/scripts linked | ✅ | Table at bottom links 3 reference docs, 2 scripts, 3 templates |

**Supporting files inventory:**

| File | Lines | Purpose |
|---|---|---|
| `references/advanced-patterns.md` | 1,096 | Multi-service, Compose, Step Functions, authorizers, canary, cross-account |
| `references/api-reference.md` | 1,028 | Complete serverless.yml property reference |
| `references/troubleshooting.md` | 852 | CF limits, rollbacks, cold starts, package sizes, plugin conflicts |
| `scripts/init-serverless.sh` | 398 | Project scaffolding with TS, esbuild, offline, tests |
| `scripts/deploy-ops.sh` | 291 | Deployment operations wrapper with stage selection, confirmations |
| `assets/serverless.template.yml` | 429 | Production template: REST+HTTP API, Cognito, API keys, DynamoDB, SQS, alarms |
| `assets/webpack.config.template.js` | 109 | Webpack fallback config for non-esbuild projects |
| `assets/ci-workflow.template.yml` | 254 | Multi-stage GitHub Actions pipeline with OIDC, approval gates |

---

## b. Content Check (Web-Verified)

### CLI Commands — ✅ All verified correct
- `serverless deploy` / `deploy function -f` / `deploy --stage prod` ✅
- `serverless remove` ✅
- `serverless invoke` / `invoke local` ✅
- `serverless logs -f --tail` ✅
- `serverless info` ✅
- `serverless dev` (v4 live dev mode) ✅
- `serverless package` ✅
- `serverless login` / `SERVERLESS_ACCESS_KEY` ✅
- `serverless create --template` ✅

### serverless.yml Syntax — ✅ Verified
- `build.esbuild` top-level section: Confirmed as v4 native replacement for serverless-esbuild plugin ✅
- `stages` with `params` and `${param:key}`: Confirmed v4 syntax ✅
- Variable resolution (`${sls:stage}`, `${aws:accountId}`, `${ssm:...}`, `${terraform:...}`): Correct ✅
- `frameworkVersion: '4'`: Correct ✅

### Plugin Names — ✅ All real, v4-compatible
- `serverless-offline` — confirmed compatible ✅
- `serverless-domain-manager` — confirmed compatible ✅
- `serverless-iam-roles-per-function` — confirmed compatible ✅
- `serverless-prune-plugin` (in deploy-ops.sh) — confirmed real ✅

### Event Types — ✅ All syntactically correct
- `httpApi` (API Gateway v2) with JWT authorizer ✅
- `http` (API Gateway v1) with Cognito authorizer ✅
- `s3` with rules, existing bucket ✅
- `sqs` with `ReportBatchItemFailures` ✅
- `sns` with `filterPolicy` ✅
- `stream` (dynamodb) with `filterPatterns` ✅
- `schedule` with rate/cron ✅
- `websocket` ✅
- `stream` (kinesis) with `parallelizationFactor` ✅
- `eventBridge` with pattern ✅

### Missing Gotchas (Minor)
1. **v4 mandatory authentication** — The skill mentions `serverless login` and `SERVERLESS_ACCESS_KEY` but doesn't prominently warn that v4 *requires* authentication for ALL CLI usage. Users upgrading from v3 will hit this immediately.
2. **AWS-only in v4** — Not explicitly stated. The skill focuses on AWS (correct) but doesn't warn that v4 dropped Azure/GCP/other providers.
3. **Licensing threshold** — No mention that orgs with >$2M revenue must purchase a subscription. Free tier details omitted.
4. **ALB event type** — Not covered (Application Load Balancer triggers). Minor — less common.

### Examples — ✅ Correct
All YAML examples match verified v4 syntax. The DynamoDB filter pattern, SQS batch failures config, stage params, and esbuild build section all align with official documentation.

---

## c. Trigger Check

| Aspect | Rating | Notes |
|---|---|---|
| Specificity | ✅ Excellent | 12+ positive scenarios, 6 negative exclusions |
| False positive risk | Low | Clear delineation from SAM, CDK, Terraform, K8s |
| False negative risk | Low | Covers all major Serverless Framework use cases |
| "serverless-esbuild" in triggers | ⚠️ Minor | Could trigger for generic esbuild questions, but contextually fine since skill correctly explains v4 built-in replacement |
| Missing trigger | None significant | Could add "Serverless Compose" but it's in advanced-patterns reference |

**Description quality:** Thorough and well-structured. Both positive and negative triggers are specific enough to avoid ambiguity. The description correctly differentiates from adjacent tools (SAM, CDK, Terraform).

---

## d. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | All commands, syntax, plugin names, event types verified correct. Minor deduction: doesn't mention v4 mandatory auth, AWS-only focus, or licensing threshold. |
| **Completeness** | 4 | Exceptional coverage of core topics + 3 deep-dive references, 2 scripts, 3 templates. Missing: v4 auth/licensing gotcha, ALB events, Serverless Compose not in main body (is in reference). |
| **Actionability** | 5 | Outstanding. 20+ copy-paste YAML/bash examples, scaffolding script, deployment wrapper, production template, CI/CD pipeline. Users can go from zero to deployed. |
| **Trigger quality** | 5 | Specific positive + negative triggers with clear boundaries. Very low false-trigger risk. |
| **Overall** | **4.5** | High-quality, production-ready skill. |

---

## e. Issues

No GitHub issues required (overall ≥ 4.0, no dimension ≤ 2).

**Recommendations for future improvement (non-blocking):**
1. Add a "v4 Breaking Changes" callout box near the top mentioning mandatory auth, AWS-only, and licensing.
2. Add ALB (`alb`) event type example.
3. Consider noting `serverless-offline` TypeScript build quirk (handlers not auto-built with built-in esbuild in some edge cases).

---

## f. Tested

**Result:** ✅ PASS

Marker appended to SKILL.md: `<!-- tested: pass -->`
