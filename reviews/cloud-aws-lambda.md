# Review: aws-lambda

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:

1. **API Gateway timeout (minor inaccuracy):** SKILL.md line 142 states "Set below the API Gateway limit (29s) for HTTP-triggered functions." Since June 2024, Regional and private REST APIs can exceed 29s via a Service Quotas request. The 29s default is still correct, but the phrasing implies a hard ceiling. Suggest: "Set below the API Gateway default timeout (29s, adjustable via quota request for Regional/private REST APIs)."

2. **Runtime version examples slightly dated:** SAM, CDK, Serverless Framework, and Terraform examples all use `nodejs20.x`. While still supported, `nodejs22.x` is now available and recommended for new projects. Not wrong, but could be fresher.

3. **Trigger description could be broader:** The YAML description doesn't mention "Lambda@Edge", "CloudFront Functions", "Lambda extensions", or "response streaming" — topics covered in `references/advanced-patterns.md`. Adding these to positive triggers would improve recall for edge-computing and streaming queries.

4. **No payload size limits mentioned in SKILL.md:** Missing the 6 MB synchronous response payload limit and 256 KB async invocation payload limit — common gotchas for new users. These may be in troubleshooting but deserve a note in the Configuration table.

5. **VPC cold start claim outdated:** Line 144 mentions VPC adds cold start latency, but since Hyperplane-based ENI (late 2019), VPC cold start penalties have dropped dramatically (~1s to near-zero for warm ENIs). The troubleshooting script still warns about "~1-2s" VPC cold start. Suggest softening language.

## Structure Assessment

- ✅ YAML frontmatter with name + description
- ✅ Positive AND negative triggers in description
- ✅ SKILL.md body is 485 lines (under 500 limit)
- ✅ Imperative voice throughout
- ✅ Code examples with input/output for all 5 runtimes (Node.js, Python, Go, Rust, Java)
- ✅ References properly linked (3 deep-dive docs exist and are substantive)
- ✅ Scripts properly linked (3 executable scripts with usage/examples)
- ✅ Asset templates linked (SAM, CDK, GitHub Actions — all production-quality)

## Content Verification (web-searched)

| Claim | Status |
|-------|--------|
| Memory: 128 MB–10,240 MB | ✅ Confirmed |
| Timeout: max 900s (15 min) | ✅ Confirmed |
| API Gateway default 29s | ✅ Confirmed (but can now be increased) |
| SnapStart: Java, Python 3.12+, .NET 8+ | ✅ Confirmed |
| SnapStart not compatible with provisioned concurrency | ✅ Confirmed |
| 5 layers max, 250 MB unzipped | ✅ Confirmed |
| Container images up to 10 GB | ✅ Confirmed |
| ZIP: 50 MB direct, 250 MB unzipped | ✅ Confirmed |
| Graviton2 ~20% cheaper | ✅ Confirmed |
| 1,769 MB = 1 vCPU | ✅ Confirmed |
| HTTP API ~70% cheaper than REST API | ✅ Confirmed |
| Ephemeral storage 512 MB–10,240 MB | ✅ Confirmed |

## Trigger Assessment

- **True positive examples:** "Create a Lambda function in Python", "Deploy Lambda with SAM", "Set up SQS trigger for Lambda", "Optimize Lambda cold starts", "Add API Gateway to Lambda" → all would trigger ✅
- **True negative examples:** "Create an Azure Function", "Deploy to ECS with Fargate", "Set up a Cloudflare Worker" → correctly excluded ✅
- **Potential false negatives:** "Set up Lambda@Edge for CloudFront", "Stream response from Lambda" → might not trigger (not in description keywords)
- **False positive risk:** Low — description is well-scoped

## Verdict

High-quality skill with comprehensive coverage, production-ready templates, and well-structured reference material. The 5 minor issues above are improvements, not blockers. An AI agent could execute effectively from this skill as-is.
