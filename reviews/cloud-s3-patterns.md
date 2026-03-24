# QA Review: s3-patterns

**Skill:** `~/skillforge/cloud/s3-patterns/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ Pass | `s3-patterns` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive, 7 lines |
| Positive triggers | ✅ Pass | "Use when: working with S3, object storage, presigned URLs…" |
| Negative triggers | ✅ Pass | "Do NOT use for: EFS/EBS block storage, DynamoDB…" |
| Body under 500 lines | ✅ Pass | 494 lines |
| Imperative voice | ✅ Pass | Consistent throughout ("Create buckets…", "Use multipart…", "Generate server-side only…") |
| Code examples | ✅ Pass | Python (boto3), JavaScript (SDK v3), bash (AWS CLI), JSON (policies) |
| Resources linked from SKILL.md | ✅ Pass | All 7 linked files exist and are substantive |

**Linked resources verified:**
- `references/advanced-patterns.md` (637 lines) — S3 Express, Object Lambda, Batch Ops, Access Grants, data lake, Object Lock, CF signed URLs
- `references/troubleshooting.md` (633 lines) — 403 debugging, slow transfers, 503 errors, CORS, versioning, lifecycle, replication, encryption, cost
- `scripts/s3-setup.sh` (253 lines) — Production bucket setup script
- `scripts/s3-sync.sh` (330 lines) — Smart sync with verification
- `assets/bucket-policy.json` (221 lines) — 5 policy templates
- `assets/lifecycle-rules.json` (205 lines) — 6 lifecycle rule templates
- `assets/cloudformation-s3.yaml` (350 lines) — Full CFn template with replication, alarms, logging

---

## B. Content Check

### Claims Verified via Web Search

| Claim | Verdict | Source |
|---|---|---|
| Bucket names: 3–63 chars, lowercase, no underscores, DNS-compliant | ✅ Correct | AWS docs |
| Presigned URL max expiry: 7 days (IAM user), session duration (STS) | ✅ Correct | AWS docs |
| Request rate: 3,500 PUT/5,500 GET per second per prefix | ✅ Correct | AWS docs |
| Multipart: required >5 GB, max 10,000 parts, 5 MB–5 GB each | ✅ Correct | AWS docs |
| SSE-S3 enabled by default on new buckets (since Jan 2023) | ✅ Correct | AWS docs |
| ACLs deprecated; use BucketOwnerEnforced | ✅ Correct | AWS docs |
| Versioning cannot be disabled, only suspended | ✅ Correct | AWS docs |
| OAC recommended over legacy OAI for CloudFront | ✅ Correct | AWS docs |
| Replication does not replicate existing objects | ✅ Correct | AWS docs |

### Issues Found

#### 🐛 BUG: `scripts/s3-sync.sh` — Include/exclude filter ordering is wrong (lines 265–270)

The script places `--exclude "*"` **after** `--include` patterns:
```bash
"${AWS_CMD[@]}" s3 sync "${SOURCE}" "${DEST}" \
    "${INCLUDE_ARGS[@]}" \     # --include "*.py"
    "${EXCLUDE_ARGS[@]}" \     # --exclude "*.pyc"
    --exclude "*" \            # ← WRONG POSITION
```

AWS CLI processes filters left-to-right with **last match wins**. Since `--exclude "*"` matches everything and comes last, ALL files are excluded — including those matched by `--include`. The correct order is `--exclude "*"` FIRST, then `--include` patterns:
```bash
--exclude "*" --include "*.py" --exclude "*.pyc"
```

**Severity:** High — script silently syncs nothing when `--include` is used.

#### ⚠️ INACCURACY: `references/troubleshooting.md` — Lambda presigned URL expiry (line 248)

The table states:
> Lambda execution role: ≤15 minutes (function timeout)

This is misleading. Lambda's presigned URL expiry is bounded by the **execution role credential rotation** (~6 hours), not the function timeout (max 15 min). A presigned URL generated inside Lambda remains valid well beyond the function's execution.

**Severity:** Medium — could lead users to over-engineer URL renewal for Lambda.

#### ℹ️ MINOR: `assets/bucket-policy.json` — Cross-account ACL enforcement conflicts with guidance

The cross-account policy template enforces `bucket-owner-full-control` ACL (line 108), but the main skill body advises disabling ACLs entirely via `BucketOwnerEnforced`. With `BucketOwnerEnforced`, any PutObject request specifying an ACL will be rejected. The template should note that this policy is for buckets that have NOT adopted `BucketOwnerEnforced`.

**Severity:** Low — templates include `_description` but don't flag this conflict.

#### ℹ️ MINOR: Bucket naming — periods allowed but omitted

The skill says "no underscores" but doesn't mention that periods (`.`) are technically allowed in bucket names. Periods should be avoided for Transfer Acceleration and SSL virtual-hosted access. A brief note would help.

### Missing Gotchas (nice to have)

- No mention of S3 Object Ownership and its interaction with cross-account writes in the main SKILL.md
- S3 Inventory first delivery can take up to 48 hours (not mentioned)
- CloudFront cache invalidation cost ($0.005/path after first 1,000/month) when used with S3

---

## C. Trigger Check

### Description Analysis

**Strengths:**
- Very comprehensive keyword coverage: lists all major S3 features explicitly
- Clear positive triggers covering common use cases
- Good negative triggers excluding EFS/EBS, DynamoDB, RDS, local filesystem, GCS/Azure Blob

**Weaknesses:**
- "object storage" is generic and could false-trigger for GCS or Azure Blob conceptual discussions (partially mitigated by negative trigger)
- Could add negative triggers for: "CloudFront-only questions without S3 origin", "IAM policy authoring unrelated to S3"

### False Trigger Assessment

| Query | Expected | Actual Risk |
|---|---|---|
| "How do I upload files to S3?" | ✅ Trigger | Correct |
| "Generate a presigned URL for S3 download" | ✅ Trigger | Correct |
| "Set up S3 lifecycle rules" | ✅ Trigger | Correct |
| "What is object storage?" | ❌ Should not trigger | ⚠️ Might trigger (generic) |
| "Configure EBS volumes" | ❌ Should not trigger | ✅ Excluded |
| "Azure Blob Storage setup" | ❌ Should not trigger | ✅ Excluded |
| "CloudFront caching without S3" | ❌ Should not trigger | ⚠️ Might trigger on "CloudFront" |

**Overall trigger quality:** Good with minor false-positive risk on generic queries.

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4/5 | All SKILL.md claims verified correct. Bug in s3-sync.sh script (include/exclude ordering). Minor inaccuracy in troubleshooting doc (Lambda presigned URL expiry). |
| **Completeness** | 5/5 | Exceptionally thorough. Covers all major S3 features across SKILL.md + 2 deep-dive references + 2 scripts + 3 asset templates. Data lake, event-driven, compliance patterns all covered. |
| **Actionability** | 5/5 | Every section has copy-paste code examples in 3+ languages/tools. Production-ready scripts and CloudFormation template. Step-by-step troubleshooting flowcharts. |
| **Trigger Quality** | 4/5 | Comprehensive positive/negative triggers. Minor false-positive risk on generic "object storage" or "CloudFront" queries. |

### **Overall Score: 4.5 / 5.0**

---

## E. GitHub Issues

**Overall ≥ 4.0 and no dimension ≤ 2** → No GitHub issues required.

*Note: The s3-sync.sh bug (include/exclude ordering) should still be fixed as a high-priority maintenance item.*

---

## F. Test Status

**Result: PASS** ✅

The skill is comprehensive, accurate in its core content, and highly actionable. The script bug and minor doc inaccuracy do not affect the overall quality threshold. Fix items are documented above.

---

## Summary of Action Items

1. **Fix** `scripts/s3-sync.sh` lines 265–270: move `--exclude "*"` before include args
2. **Fix** `references/troubleshooting.md` line 248: Lambda presigned URL expiry is bounded by credential rotation (~6 hrs), not function timeout
3. **Consider** adding a note to `assets/bucket-policy.json` cross-account template about BucketOwnerEnforced conflict
4. **Consider** mentioning periods in bucket names (allowed but discouraged for SSL)
