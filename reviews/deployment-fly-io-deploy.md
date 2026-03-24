# QA Review: fly-io-deploy

**Skill path:** `~/skillforge/deployment/fly-io-deploy/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter — `name` | ✅ Pass | `fly-io-deploy` |
| YAML frontmatter — `description` with positive triggers | ✅ Pass | Covers flyctl, fly.toml, Machines API, Fly Postgres, Tigris, LiteFS, GPU, CI/CD, etc. |
| YAML frontmatter — negative triggers | ✅ Pass | Excludes Kamal, Caddy, AWS/GCP/Azure/Heroku/Railway/Render, generic Docker, Kubernetes |
| Body under 500 lines | ✅ Pass | 488 lines (12 lines under limit) |
| Imperative voice | ✅ Pass | Consistently uses imperative ("Install", "Set", "Use", "Deploy") |
| Examples with input/output | ✅ Pass | CLI commands, TOML configs, code snippets, and step-by-step walkthroughs throughout |
| References linked from SKILL.md | ✅ Pass | Table at bottom links all 3 reference files with topic descriptions |
| Scripts linked from SKILL.md | ✅ Pass | Table at bottom links all 3 scripts with purpose and usage |
| Assets linked from SKILL.md | ✅ Pass | Table at bottom links all 5 asset files with descriptions |

**Structure verdict:** All criteria met.

---

## b. Content Check (Web-Verified)

### Verified Correct ✅

| Claim | Verification |
|-------|-------------|
| `flyctl` commands (`fly launch`, `fly deploy`, `fly scale`, `fly secrets`, etc.) | Confirmed against Fly.io CLI docs |
| Machines API base URL `https://api.machines.dev/v1` | Confirmed |
| `fly.toml` sections (`[http_service]`, `[build]`, `[deploy]`, `[[vm]]`, `[mounts]`, `[processes]`) | Confirmed against fly.toml reference |
| Deploy strategies: `rolling`, `immediate`, `canary`, `bluegreen` | All confirmed as valid `[deploy] strategy` values |
| `auto_stop_machines` accepts `"stop"`, `"suspend"`, or `false` | Confirmed |
| Regions: 30+ globally | Confirmed (35+ data centers) |
| Firecracker microVMs, ~300ms cold start | Confirmed |
| Fly Postgres backed by Supabase | Confirmed |
| Tigris S3-compatible storage, no egress fees | Confirmed |
| LiteFS distributed SQLite via FUSE | Confirmed |
| Upstash Redis integration via `fly redis create` | Confirmed |
| GPU types: `a100-40gb`, `a100-80gb`, `l40s`, `a10` | Confirmed |
| GPU pricing ~$2.50/hr for A100-40gb | Confirmed |
| `fly-replay` header for transparent request replay | Confirmed |
| WireGuard mesh private networking, `.internal` DNS | Confirmed |
| Free tier: 3 shared-cpu-1x Machines, 3GB volume storage, 160GB bandwidth | Confirmed |
| Volume pricing ~$0.15/GB/mo | Confirmed |
| Let's Encrypt auto-provisioned TLS | Confirmed |
| `release_command` runs in temporary Machine before deploy | Confirmed |

### Minor Inaccuracies ⚠️

| Claim in SKILL.md | Actual | Severity |
|----|--------|----------|
| `shared-cpu-1x` costs "~$2.32/mo full-time for 256MB" (line 411) | Current pricing is **$1.94/mo** for shared-cpu-1x 256MB | Low — pricing changes frequently; the value is in the right ballpark |
| Suspend wake time "~50ms" (line 414) | Fly docs say "a few hundred milliseconds" for resume; 50ms is optimistic | Low — order of magnitude correct, but overstates speed |

### Missing Gotchas ⚠️

| Missing Item | Impact |
|-------------|--------|
| **Suspend mode limitation**: Only works for machines with ≤2GB RAM, no GPU, no swap | Medium — users may try suspend on larger VMs and be confused |
| **Blue-green + volumes**: Blue-green deploy strategy does not support apps with attached volumes | Medium — could cause deploy failures for stateful apps |
| **Vercel/Netlify not in DO NOT TRIGGER**: Only server-based competitors listed in exclusions | Low — unlikely to false-trigger but completeness gap |

### Examples Correctness

- ✅ Node.js deploy example: correct sequence (`fly launch`, edit config, `fly deploy`)
- ✅ Rails + Postgres example: correct (`fly postgres create`, `attach`, `release_command`)
- ✅ Multi-region scaling example: correct syntax
- ✅ CI/CD example: correct GitHub Actions workflow with `superfly/flyctl-actions`
- ✅ Machines API curl examples: correct endpoints, auth headers, JSON payloads
- ✅ fly-replay middleware examples (Python, Ruby, JS): correct pattern
- ✅ LiteFS config: correct YAML structure with Consul lease

---

## c. Trigger Check

### Would trigger for Fly.io queries? ✅ Yes

| Query | Would Trigger? |
|-------|---------------|
| "How do I deploy to Fly.io?" | ✅ Yes — matches "deploying to Fly.io" |
| "What's the fly.toml syntax for health checks?" | ✅ Yes — matches "fly.toml" |
| "How do I use the Machines API?" | ✅ Yes — matches "Fly Machines" |
| "Set up Fly Postgres" | ✅ Yes — matches "Fly Postgres" |
| "Scale my app across regions on Fly" | ✅ Yes — matches "fly scale", "multi-region deployment on Fly" |
| "Configure LiteFS for SQLite replication" | ✅ Yes — matches "LiteFS" |
| "Fly.io GPU machine setup" | ✅ Yes — matches "Fly GPU machines" |
| "fly secrets management" | ✅ Yes — matches "fly secrets" |

### Would falsely trigger for competitors? ✅ No

| Query | Would Trigger? | Reason |
|-------|---------------|--------|
| "Deploy my app to Railway" | ❌ No | "Railway" in DO NOT TRIGGER |
| "Set up Render deployment" | ❌ No | "Render" in DO NOT TRIGGER |
| "Deploy to Vercel" | ❌ No | No positive trigger match (Vercel is serverless, not matching any Fly.io keywords) |
| "Configure Kubernetes deployment" | ❌ No | "Kubernetes orchestration" in DO NOT TRIGGER |
| "Deploy with Kamal" | ❌ No | "Kamal" in DO NOT TRIGGER |
| "Set up Heroku pipeline" | ❌ No | "Heroku" in DO NOT TRIGGER |
| "AWS ECS deployment" | ❌ No | "AWS" in DO NOT TRIGGER |
| "Generic Docker Compose setup" | ❌ No | "generic Docker without Fly context" in DO NOT TRIGGER |

**Trigger verdict:** Strong positive coverage of Fly.io ecosystem. Negative triggers correctly exclude competitors. No false-trigger risk identified.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All major technical claims verified. Minor pricing discrepancy ($2.32 vs $1.94) and optimistic suspend wake time (~50ms vs hundreds of ms). No critical errors. |
| **Completeness** | 5 | Exceptionally thorough. Covers architecture, CLI, config, API, deploy strategies, scaling (horizontal/vertical/auto), volumes, 4 database options, secrets, domains, private networking, multi-region patterns, Dockerfiles, CI/CD, monitoring, cost optimization, and 10 common pitfalls. Three deep-dive reference guides, three utility scripts, and five template assets. |
| **Actionability** | 5 | Every section provides copy-paste-ready commands, configs, or code. Scripts (`fly-init.sh`, `fly-scale.sh`, `fly-db-setup.sh`) are immediately usable with proper arg parsing, validation, and help text. Assets provide production-grade templates. Examples cover Node.js, Rails, Django, Flask, Go, and static sites. |
| **Trigger quality** | 4 | Positive triggers cover the full Fly.io ecosystem comprehensively. Negative triggers exclude major competitors. Minor gap: Vercel/Netlify/DigitalOcean not explicitly excluded (though unlikely to false-trigger). |
| **Overall** | **4.5** | High-quality, production-ready skill. |

---

## e. GitHub Issues

**No issues required.** Overall score (4.5) ≥ 4.0 and no individual dimension ≤ 2.

---

## f. Recommendations (non-blocking)

1. **Update pricing**: Change `shared-cpu-1x` cost from ~$2.32/mo to ~$1.94/mo (or use "~$2/mo" to future-proof).
2. **Add suspend limitations**: Note ≤2GB RAM requirement for `auto_stop_machines = "suspend"`.
3. **Add blue-green + volumes caveat**: Note that blue-green deploy strategy doesn't support apps with volumes.
4. **Add Vercel/Netlify to DO NOT TRIGGER**: For completeness, though false-trigger risk is negligible.
5. **Moderate suspend wake claim**: Change "~50ms wake" to "sub-second wake" or "~100-500ms wake".

---

**Review path:** `~/skillforge/reviews/deployment-fly-io-deploy.md`
**Status:** ✅ PASS
