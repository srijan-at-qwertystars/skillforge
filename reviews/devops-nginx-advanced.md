# QA Review: nginx-advanced

**Skill path**: `devops/nginx-advanced/SKILL.md`
**Reviewed**: <!-- auto --> date placeholder replaced below
**Verdict**: ✅ PASS

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | `name`, `description` with positive and negative triggers |
| Positive triggers | ✅ | 30+ Nginx-specific terms (proxy, upstream, SSL, rate limiting, etc.) |
| Negative triggers | ✅ | Explicitly excludes Apache httpd, Caddy, Traefik, HAProxy, Envoy |
| Line count | ✅ | 471 lines (under 500 limit) |
| Imperative voice | ✅ | Declarative/reference style appropriate for config skill |
| Input→Output examples | ✅ | 3 examples (WebSocket+SSL proxy, rate-limit+cache, sticky LB) |
| References linked | ✅ | 3 reference docs, 3 scripts, 4 assets, 3 njs examples — all verified present |

## b. Content Check

All key directives verified against official Nginx docs and current best practices:

| Topic | Accuracy | Notes |
|-------|----------|-------|
| Location match priority | ✅ | Correct order: exact → `^~` → regex → longest prefix |
| `proxy_pass` + headers | ✅ | Correct upstream, keepalive, forwarded headers |
| SSL/TLS termination | ✅ | Protocols, ciphers, OCSP stapling, HSTS all correct |
| `ssl_prefer_server_ciphers off` | ✅ | Correct modern practice — TLS 1.3 ignores this directive |
| HTTP/2 `http2 on;` directive | ✅ | Correctly documents new 1.25.1+ syntax in HTTP/2 section |
| Rate limiting | ✅ | `limit_req_zone`, `burst`, `nodelay` syntax all verified |
| Caching (proxy + FastCGI) | ✅ | `proxy_cache_path`, `proxy_cache_use_stale`, skip logic correct |
| WebSocket proxying | ✅ | `map` + Upgrade/Connection headers correct |
| Stream module | ✅ | Correctly notes placement outside `http {}` |
| Security headers | ✅ | `X-XSS-Protection "0"` is correct (XSS Auditor deprecated) |
| Map directive | ✅ | Lazy evaluation note is accurate |
| Compression | ✅ | Gzip + Brotli with correct MIME types |

### Minor Issues

1. **SSL section uses old `listen 443 ssl http2;`** (line 112) while the HTTP/2 section correctly uses `http2 on;` (line 143). The old syntax works but is deprecated since 1.25.1. The skill acknowledges the change but the SSL example itself uses the old form — a small inconsistency.

2. **`proxy_pass` trailing-slash gotcha not in main body.** The difference between `proxy_pass http://backend` (forwards full URI) vs `proxy_pass http://backend/` (strips location prefix) is the #1 Nginx footgun. It's covered in `references/troubleshooting.md` but a one-line warning in the Reverse Proxy section would prevent many misconfigurations.

### Missing Gotchas (minor)

- No mention of `proxy_pass` with variables disabling URI rewriting and requiring explicit `resolver` directive.
- No `if` is evil caveat (well-known Nginx anti-pattern); the rewrite section uses `if` without a warning.

## c. Trigger Check

| Scenario | Would Trigger? | Correct? |
|----------|---------------|----------|
| "Configure nginx reverse proxy" | ✅ Yes | ✅ |
| "nginx rate limiting per IP" | ✅ Yes | ✅ |
| "nginx SSL certificate setup" | ✅ Yes | ✅ |
| "Set up Apache virtual hosts" | ❌ No | ✅ |
| "Caddy automatic HTTPS" | ❌ No | ✅ |
| "Traefik Docker labels" | ❌ No | ✅ |
| "Envoy proxy configuration" | ❌ No | ✅ |
| "HAProxy backend health checks" | ❌ No | ✅ |
| "Generic web server concepts" | ❌ No | ✅ |

Trigger specificity is excellent — 30+ Nginx-specific terms with explicit competitor exclusions.

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All directives verified correct. Minor inconsistency with deprecated `listen ... http2` in SSL example. |
| **Completeness** | 5 | Covers performance, locations, proxy, LB, SSL, HTTP/2-3, rate limiting, caching, compression, security headers, WebSocket, map, rewrite, access control, logging, stream module, plus references/scripts/assets/njs. |
| **Actionability** | 5 | Production-ready configs, 3 input→output examples, 3 operational scripts, 4 config templates, 3 njs examples. |
| **Trigger quality** | 4 | Comprehensive positive triggers and good negative exclusions. |
| **Overall** | **4.5** | Excellent, well-organized skill. Minor fixes would bring it to 5. |

## e. Recommendations

1. Update SSL example (line 112) to use `listen 443 ssl;` + `http2 on;` for consistency with the HTTP/2 section.
2. Add a one-line `proxy_pass` trailing-slash warning in the Reverse Proxy section.
3. Consider adding a brief `if` directive caveat in the Rewrite Rules section.

---

*No GitHub issue filed — overall score ≥ 4.0 and no dimension ≤ 2.*
