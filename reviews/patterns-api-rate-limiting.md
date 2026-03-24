# QA Review: api-rate-limiting

**Skill:** `patterns/api-rate-limiting`
**Reviewer:** Copilot CLI (automated QA)
**Date:** 2025-07-17
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ | `api-rate-limiting` |
| YAML frontmatter `description` | ✅ | Multi-line, comprehensive |
| Positive triggers | ✅ | 14 triggers: "rate limiting", "throttling API", "429 responses", "token bucket", "leaky bucket", "sliding window rate limit", "API quota", "request throttling", "too many requests", "rate limiter middleware", "Retry-After header", "RateLimit header", "burst limiting", "cost-based rate limit" |
| Negative triggers | ✅ | 6 exclusions: circuit breakers, load balancing, DDoS (network level), connection pooling, caching strategies, auth/authz logic |
| Body under 500 lines | ✅ | 495 total lines (488 body lines after frontmatter) |
| Imperative voice | ✅ | Consistent throughout: "Pick the algorithm", "Use for", "Include on ALL responses", "Always use Lua scripts", "Always respect Retry-After" |
| Examples with I/O | ✅ | Example 1: "Add rate limiting to my Express API" (input → full middleware output). Example 2: "Handle 429 responses in my Python client" (input → retry logic output) |
| Resources properly linked | ✅ | Supplemental Files section references all 3 references, 3 scripts, and 5 assets with descriptions |

**Structure verdict:** All criteria met.

---

## B. Content Check

### Rate Limiting Algorithms

| Algorithm | Accuracy | Notes |
|---|---|---|
| Token Bucket | ✅ Correct | Bucket holds tokens, refills at fixed rate, allows burst up to capacity. Matches standard definition. |
| Leaky Bucket | ✅ Correct | Queue drains at fixed rate, no burst. Correctly distinguishes meter vs queue modes in references. |
| Sliding Window Log | ✅ Correct | Sorted set of timestamps, ZREMRANGEBYSCORE to expire, O(n) memory tradeoff accurately noted. |
| Sliding Window Counter | ✅ Correct | Weighted interpolation `prev_count × (1 - elapsed_fraction) + curr_count`. ~99.7% accuracy claim aligns with Cloudflare's published analysis. |
| Fixed Window | ✅ Correct | 2x boundary burst flaw correctly identified. |
| Comparison table | ✅ Correct | Memory, accuracy, and burst characteristics match verified sources. |

### Redis Lua Scripts

| Script | Correctness | Notes |
|---|---|---|
| `assets/token-bucket.lua` | ✅ Correct | Atomic HMGET → refill calc → HSET. Proper EXPIRE for idle key cleanup. Returns JSON with `allowed`, `remaining`, `retry_after`. |
| `assets/sliding-window.lua` | ✅ Correct | Weighted interpolation between two window counters. INCR + conditional EXPIRE. Returns JSON. |
| SKILL.md inline scripts | ✅ Correct | Sliding window log (ZADD/ZREMRANGEBYSCORE), token bucket, fixed window (INCR+EXPIRE) all use correct atomic patterns. |
| Atomicity advice | ✅ Correct | "Always use Lua scripts (EVAL/EVALSHA) for atomicity. Never use separate GET+SET." Verified against Redis docs. |

### HTTP Header Standards

| Item | Accuracy | Notes |
|---|---|---|
| `RateLimit-Limit/Remaining/Reset` | ✅ Pragmatically correct | Matches widely-adopted format from earlier IETF drafts. |
| IETF draft reference | ⚠️ Minor note | Latest draft revisions (draft-10+) consolidate into `RateLimit` + `RateLimit-Policy` structured headers. The three-header approach is from earlier drafts but remains the de facto industry standard (used by GitHub, Stripe, etc.). Pragmatically correct for practitioners. |
| `Retry-After` on 429 | ✅ Correct | Seconds format (integer) preferred for machine parsing. RFC 7231 §7.1.3 defines the header. |
| RFC 6585 citation | ⚠️ Minor note | RFC 6585 defines 429 status code but says "MAY" include Retry-After. The skill's advice to "always include" is best practice, not a strict RFC mandate. |
| Legacy `X-RateLimit-*` headers | ✅ Correct | Good backward compatibility advice. |

### Nginx Rate Limiting

| Directive | Accuracy | Notes |
|---|---|---|
| `limit_req_zone` | ✅ Correct | `$binary_remote_addr zone=api:10m rate=10r/s` — correct syntax, correct context (http block). |
| `limit_req` | ✅ Correct | `burst=20 nodelay` — correctly explained. |
| `limit_req_status 429` | ✅ Correct | Default is 503; explicitly setting 429 is correct and important. |
| `assets/nginx-rate-limit.conf` | ✅ Correct | Multiple zones (per-IP, per-key, auth, expensive), geo-based allowlisting, custom 429 error page, all syntactically valid. |

### Kong Plugin Configuration

| Item | Accuracy | Notes |
|---|---|---|
| SKILL.md body snippet | ⚠️ Minor note | Uses older flat `redis_host`/`redis_port` format. Kong 3.x+ declarative configs use nested `redis.host`/`redis.port`. Still functional for Admin API calls. |
| `assets/kong-rate-limit.yaml` | ✅ Correct | Uses `_format_version: "3.0"` with correct nested `redis:` block. Per-consumer, per-route, tiered limits. `fault_tolerant`, `limit_by`, `sync_rate` all valid config keys. |
| `rate-limiting-advanced` note | ✅ Correct | Correctly noted as Kong Enterprise only for sliding window. |

### Additional Content

- **Middleware implementations** (Express, FastAPI, Go, Django): All correct patterns.
- **Client retry with backoff**: Correct exponential backoff + jitter + Retry-After respect.
- **Distributed rate limiting**: Fail-open vs fail-closed decision matrix is sound.
- **References**: Algorithm deep-comparison, advanced patterns (adaptive, WebSocket, GraphQL cost, sidecar, quotas), troubleshooting (race conditions, clock skew, header spoofing, IPv6, hot keys, monitoring) — all technically accurate and thorough.
- **Scripts**: Well-structured with usage docs, env vars, error handling.

**Content verdict:** Technically accurate throughout. Three minor notes (IETF draft evolution, RFC 6585 phrasing, Kong body snippet format) — none are errors that would mislead practitioners.

---

## C. Trigger Check

| Query | Should Trigger? | Would Trigger? | Result |
|---|---|---|---|
| "Add rate limiting to my Express API" | Yes | ✅ Yes — matches "rate limiting" | ✅ |
| "How to implement token bucket in Redis" | Yes | ✅ Yes — matches "token bucket" | ✅ |
| "Handle 429 Too Many Requests errors" | Yes | ✅ Yes — matches "429 responses", "too many requests" | ✅ |
| "API quota management for SaaS tiers" | Yes | ✅ Yes — matches "API quota" | ✅ |
| "Add Retry-After header to responses" | Yes | ✅ Yes — matches "Retry-After header" | ✅ |
| "Sliding window counter rate limiter" | Yes | ✅ Yes — matches "sliding window rate limit" | ✅ |
| "Implement a circuit breaker pattern" | No | ✅ No — explicitly excluded | ✅ |
| "Load balancing across servers" | No | ✅ No — explicitly excluded | ✅ |
| "Redis caching strategy for API" | No | ✅ No — excluded (caching strategies) | ✅ |
| "DDoS protection with iptables" | No | ✅ No — excluded (DDoS at network level) | ✅ |
| "OAuth2 authentication setup" | No | ✅ No — excluded (auth/authz logic) | ✅ |
| "Connection pooling in Node.js" | No | ✅ No — explicitly excluded | ✅ |

**Trigger verdict:** Clean separation. 14 positive triggers cover the domain well. 6 negative exclusions prevent false activation on adjacent topics.

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 5 | All algorithms, Redis scripts, Nginx/Kong configs, and HTTP headers are technically correct. Three minor notes (IETF draft evolution, RFC phrasing, Kong snippet format) are cosmetic and don't mislead. |
| **Completeness** | 5 | Covers 5 algorithms with comparison tables and decision flowchart, Redis Lua scripts (3 algorithms), HTTP headers (standard + legacy + 429), middleware for 4 frameworks, 3 reverse proxies, 2 API gateways, client retry with backoff, distributed approaches, fail-open/fail-closed. References add advanced patterns (adaptive, WebSocket, GraphQL cost, sidecar, quotas), troubleshooting (race conditions, clock skew, header spoofing, IPv6, hot keys, monitoring). Scripts for testing, benchmarking, and header auditing. |
| **Actionability** | 5 | Every section has copy-paste code. Decision flowchart for algorithm selection. Quick reference table. Two detailed examples with labeled Input/Output. Production-ready Lua scripts, TypeScript middleware, Nginx config, and Kong YAML in assets. Three executable shell scripts for testing. |
| **Trigger Quality** | 5 | 14 positive triggers covering common phrasings (technical terms, error codes, header names). 6 negative exclusions for adjacent patterns (circuit breakers, load balancing, DDoS, connection pooling, caching, auth). No false-positive risk identified. |

**Overall: 5.0 / 5.0**

---

## Minor Recommendations (non-blocking)

1. **IETF draft evolution**: Consider adding a note that latest drafts (draft-10+) consolidate to `RateLimit` + `RateLimit-Policy` structured headers, while the three-header approach remains the industry standard. This future-proofs the skill.
2. **Kong body snippet**: Update the SKILL.md inline Kong example to use the nested `redis:` format matching Kong 3.x+ declarative config (the asset file already uses the correct format).
3. **RFC citation**: Change "RFC 6585" to "RFC 6585 §4" and note that Retry-After inclusion is best practice (the RFC says "MAY").

---

## Disposition

- **Overall score:** 5.0 ≥ 4.0 threshold ✅
- **No dimension ≤ 2** ✅
- **GitHub issues:** Not required
- **SKILL.md annotation:** `<!-- tested: pass -->`
