# Review: vercel-deploy

Accuracy: 3/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.3/5

## Issues

### Outdated function memory limits
SKILL.md and troubleshooting.md state max memory is 3008 MB (range "128–3008 MB"). Vercel now supports up to **4 GB (4096 MB)** on Pro/Enterprise and **2 GB** on Hobby. The 3008 value is stale. Affects: SKILL.md line 59, troubleshooting.md line 227, assets/vercel.json line 43 comment.

### Outdated maxDuration limits
The troubleshooting table (line 196–200) shows Hobby: 10s, Pro: 60s default / up to 300s, Enterprise: up to 900s. Current Vercel limits (with Fluid Compute defaults) are: Hobby: 300s, Pro: 300s default / 800s max, Enterprise: 300s default / 800s max. These are significantly different and would mislead users configuring timeouts.

### Edge function code size overstated
SKILL.md Edge/Serverless comparison table (line 142) claims Edge code size is "1–4 MB". Actual limits are **1 MB (Hobby)** and **2 MB (Pro/Enterprise)**. The 4 MB figure is incorrect.

### Serverless function code size understated
Same table says serverless is "Up to 50 MB". Vercel docs state the unzipped limit is **250 MB**. The 50 MB figure appears to be outdated.

### Edge function duration row misleading
Table says Edge "Initial response <25s" but the actual behavior is: must begin streaming within 25s, can stream up to 300s total. The "Duration" column for serverless says "Up to 5–15 min" which is also now stale (see maxDuration changes above).

## Structure Assessment
- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (USE when) AND negative triggers (DO NOT USE for)
- ✅ SKILL.md is 484 lines (under 500)
- ✅ Imperative voice, no filler throughout
- ✅ Abundant code examples with context
- ✅ `references/`, `scripts/`, and `assets/` properly linked from SKILL.md
- ✅ Scripts are well-structured with `--dry-run`, `--help`, error handling
- ✅ Assets are comprehensive annotated templates

## Content Strengths
- Excellent framework coverage (Next.js, SvelteKit, Nuxt, Astro, Remix, Vite)
- Correctly identifies Vercel KV → Upstash Redis migration
- DNS IP address (76.76.21.21) verified correct
- Troubleshooting section has real error messages with specific fixes
- Scripts are production-quality bash with proper arg parsing and safety
- GitHub Actions workflow is complete with concurrency, PR comments, smoke tests

## Trigger Assessment
- Positive triggers are comprehensive: 14+ specific scenarios listed
- Negative triggers correctly exclude AWS/GCP/Azure, Docker/K8s, Netlify, Cloudflare
- Would reliably trigger for real Vercel deployment queries
- Low false-positive risk due to specific platform exclusions

## Verdict
High-quality skill with outdated numeric limits that need updating. The architecture, examples, scripts, and overall coverage are excellent. The stale numbers (memory, duration, code size) could cause real configuration errors for users following the guide.
