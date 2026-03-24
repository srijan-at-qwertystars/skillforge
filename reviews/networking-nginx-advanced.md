# QA Review: nginx-advanced

**Skill path:** `~/skillforge/networking/nginx-advanced/`  
**Reviewed:** $(date -u +%Y-%m-%d)  
**Reviewer:** Automated QA  

---

## A. Structure Check

### YAML Frontmatter

| Check | Status | Notes |
|---|---|---|
| `name` field present | ✅ PASS | `nginx-advanced` |
| `description` field present | ✅ PASS | Multi-line, detailed |
| Positive triggers in description | ✅ PASS | 28 positive trigger phrases covering proxy, SSL, caching, rate limiting, load balancing, WebSocket, HTTP/2, HTTP/3, performance tuning, etc. |
| Negative triggers in description | ✅ PASS | 9 explicit negative triggers: Apache, Caddy, Traefik, HAProxy, basic install, Docker networking, DNS, firewall, certbot standalone |

### Body Size

| Check | Status | Notes |
|---|---|---|
| SKILL.md under 500 lines | ✅ PASS | 464 lines |

### Voice and Style

| Check | Status | Notes |
|---|---|---|
| Imperative voice | ✅ PASS | "Structure configs modularly", "Always pass real client information", "Always test before applying" |
| No filler | ✅ PASS | Dense, no preamble or hedging language |
| Examples with input/output | ✅ PASS | Every section has config blocks with inline comments explaining behavior |

### File Linking

| Check | Status | Notes |
|---|---|---|
| references/ linked from SKILL.md | ✅ PASS | Table at line 429 links all 3 reference docs with topic summaries |
| scripts/ linked from SKILL.md | ✅ PASS | Table at line 439 links all 3 scripts with usage examples |
| assets/ linked from SKILL.md | ✅ PASS | Table at line 460 links all 3 config templates |

### File Inventory

| File | Lines | Status |
|---|---|---|
| SKILL.md | 464 | ✅ |
| references/advanced-patterns.md | 902 | ✅ |
| references/troubleshooting.md | 805 | ✅ |
| references/security-hardening.md | 919 | ✅ |
| scripts/generate-ssl.sh | 286 | ✅ |
| scripts/test-config.sh | 335 | ✅ |
| scripts/log-analyzer.sh | 373 | ✅ |
| assets/reverse-proxy.conf | 159 | ✅ |
| assets/load-balancer.conf | 231 | ✅ |
| assets/security-headers.conf | 80 | ✅ |

---

## B. Content Check

### Accuracy Verification

| Claim | Verified | Status |
|---|---|---|
| Location matching order: `=` → `^~` → `~`/`~*` → prefix | ✅ Confirmed via nginx docs & multiple sources | ✅ PASS |
| `proxy_pass` trailing slash strips location prefix | ✅ Confirmed — `http://backend/` strips, `http://backend` preserves | ✅ PASS |
| `add_header` in child block clears parent headers | ✅ Confirmed — well-documented nginx behavior | ✅ PASS |
| `$binary_remote_addr` is 4 bytes (IPv4) | ⚠️ Partially accurate | ⚠️ MINOR |
| `ssl_prefer_server_ciphers off` for TLS 1.3 | ✅ Correct — TLS 1.3 ignores server preference; `off` is appropriate | ✅ PASS |
| `listen 443 ssl http2` syntax | ⚠️ Deprecated since nginx 1.25.1 | ⚠️ ISSUE |
| Keepalive requires `proxy_set_header Connection ""` | ✅ Confirmed — clears hop-by-hop header | ✅ PASS |
| `hash $request_uri consistent` uses ketama | ✅ Confirmed — consistent hashing with minimal redistribution | ✅ PASS |
| OSS nginx has passive checks only | ✅ Correct — active health checks are NGINX Plus or third-party modules | ✅ PASS |

### Accuracy Issues Found

1. **`$binary_remote_addr` size claim (line 170):** States "16 bytes" — this is correct for IPv6 but the parenthetical says `$remote_addr` is "7-15 bytes variable." The `$binary_remote_addr` is 4 bytes for IPv4 and 16 bytes for IPv6; the skill text conflates the IPv6 binary size. The recommendation to use `$binary_remote_addr` is correct but the stated size is misleading — readers may think it's always 16 bytes.

2. **HTTP/2 `listen` directive (lines 131, 278):** Uses `listen 443 ssl http2;` throughout. Since nginx 1.25.1 (released June 2023), the `http2` parameter on the `listen` directive is deprecated. The new syntax is `http2 on;` as a standalone directive. The skill should document both forms with a version note, since many production systems still run pre-1.25 nginx.

3. **Location matching description (line 218):** States regex matches by "first matching regex in config order" — this is correct. However, the anti-pattern note at line 232 says "placing a regex above a `^~` prefix and expecting the prefix to win" — this is slightly confusingly worded. The `^~` always beats regex regardless of position; it's about expecting the regex to win over `^~`, not vice versa. The description is technically correct but could mislead.

### Missing Gotchas

1. **`proxy_next_upstream` and non-idempotent retries:** Covered excellently in troubleshooting.md (line 198-205) but not mentioned in the main SKILL.md load balancing section. This is a critical production foot-gun — POST requests being silently retried can cause double-charges, duplicate writes, etc.

2. **`root` vs `alias` with trailing slash in location:** The anti-patterns table mentions this briefly but doesn't show the dangerous case where `location /images/ { root /data; }` serves from `/data/images/` while `alias /data/` would serve from `/data/`.

3. **No mention of `proxy_intercept_errors`:** Needed for custom error pages to work with proxy_pass. The assets/reverse-proxy.conf has `error_page` but comments don't mention needing `proxy_intercept_errors on;`.

4. **No `add_header_inherit merge` (nginx 1.29+):** The skill correctly warns about header inheritance loss but doesn't mention the new merge directive available in nginx 1.29+. Minor since it's very recent.

### Example Correctness

| Example | Runnable? | Notes |
|---|---|---|
| Reverse proxy snippet | ✅ | Correct syntax, proper headers |
| Load balancing upstreams | ✅ | All algorithms correctly shown |
| SSL/TLS config | ✅ | Valid cipher suites, correct OCSP setup |
| Rate limiting | ✅ | Correct zone definitions and application |
| WebSocket proxy | ✅ | Correct map + upgrade headers |
| Proxy cache | ✅ | Valid cache_path and directives |
| generate-ssl.sh | ✅ | Proper openssl commands with SAN, error handling |
| test-config.sh | ✅ | Robust security audit checks |
| log-analyzer.sh | ✅ | Correct awk/grep patterns for common log format |
| assets/reverse-proxy.conf | ✅ | Production-ready, CHANGEME markers present |
| assets/load-balancer.conf | ✅ | Comprehensive with WebSocket, sticky sessions |
| assets/security-headers.conf | ✅ | Thorough with explanatory comments |

### Would an AI Execute Perfectly?

**Mostly yes.** The skill provides enough detail for an AI to generate correct nginx configs for most scenarios. The HTTP/2 deprecation issue could cause warnings on newer nginx versions. The proxy_next_upstream caveat for POSTs is hidden in a reference file rather than prominently placed in the main skill body where it's most needed.

---

## C. Trigger Check

### Positive Trigger Analysis

The description lists 28 specific trigger phrases. Coverage is excellent:

- ✅ Core topics: reverse proxy, load balancer, SSL/TLS, rate limiting, caching
- ✅ Specific directives: proxy_pass, worker_processes, fastcgi_cache, proxy_cache
- ✅ Advanced topics: WebSocket, HTTP/2, HTTP/3, upstream health check, gzip
- ✅ Operational: performance tuning, hardening, security headers, map directive, rewrite rules, buffer tuning

**Verdict:** Strong positive triggering. Would reliably activate for any nginx configuration query.

### False Trigger Analysis

| Scenario | Would it falsely trigger? | Notes |
|---|---|---|
| Apache httpd config | ❌ No | Explicitly excluded |
| Caddy server setup | ❌ No | Explicitly excluded |
| Traefik proxy routing | ❌ No | Explicitly excluded |
| HAProxy configuration | ❌ No | Explicitly excluded |
| Generic "reverse proxy" without nginx context | ⚠️ Possible | Keyword "reverse proxy" alone could match. Low risk — context usually disambiguates. |
| "SSL certificate" without nginx context | ⚠️ Possible | "nginx SSL/TLS" is a trigger but the nginx qualifier helps. |
| Basic `apt install nginx` | ❌ No | "basic nginx install or package management" is excluded |
| Docker networking | ❌ No | Explicitly excluded unless nginx-related |

**Verdict:** Good negative boundary. The negative triggers are well-scoped. Minimal false positive risk.

---

## D. Scoring

| Dimension | Score | Justification |
|---|---|---|
| **Accuracy** | 4 | Core nginx behavior is correct. Minor issue: HTTP/2 `listen` syntax is deprecated since 1.25.1 (June 2023). `$binary_remote_addr` size description slightly misleading. All other claims verified. |
| **Completeness** | 5 | Exceptionally thorough. SKILL.md covers all major nginx topics. Three deep reference docs (2600+ lines total). Three utility scripts. Three production config templates. Anti-patterns table. Nothing major missing. |
| **Actionability** | 5 | Every section has copy-paste-ready config blocks. Scripts are executable with clear usage headers. Config templates use CHANGEME markers. Anti-patterns table gives fix for each issue. An engineer can go from zero to production config. |
| **Trigger Quality** | 5 | 28 positive triggers cover the full nginx surface area. 9 negative triggers precisely exclude adjacent tools. No obvious gaps in trigger coverage. |

### Overall Score: **4.75 / 5.0**

---

## E. Issue Filing

**Overall ≥ 4.0 and no dimension ≤ 2.** No GitHub issues required.

### Recommendations (non-blocking)

1. **Add HTTP/2 deprecation note:** Add version-aware guidance for `listen 443 ssl http2` vs `http2 on;` (nginx 1.25.1+). Both the SKILL.md HTTP/2 section and asset configs should note this.

2. **Surface `proxy_next_upstream` warning in SKILL.md:** The POST retry danger is in troubleshooting.md but deserves a one-line callout in the Load Balancing section of SKILL.md.

3. **Clarify `$binary_remote_addr` size:** Change "(16 bytes)" to "(4 bytes IPv4, 16 bytes IPv6)" for precision.

4. **Consider mentioning `proxy_intercept_errors`:** Add to the reverse-proxy template's error_page section.

---

## F. Test Status

**Result: PASS**

The skill is well-structured, technically accurate (with minor version-sensitivity notes), comprehensive, and highly actionable. The trigger description is well-tuned with proper negative boundaries.
