# QA Review: security-headers

**Skill path:** `~/skillforge/security/security-headers/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter name + description | ✅ | `name: security-headers`, multi-line description present |
| Positive triggers in description | ✅ | 20+ specific triggers: CSP, HSTS, X-Frame-Options, COEP, COOP, CORP, Helmet.js, cookie prefixes, nonce, strict-dynamic, report-to, etc. |
| Negative triggers in description | ✅ | 10 exclusions: HTTP caching strategy, cookie consent banners, CORS preflight, OAuth/OIDC, TLS certs, SSL termination, firewall rules, WAF config, rate limiting |
| Body under 500 lines | ✅ | 489 lines (just under limit) |
| Imperative voice | ✅ | "Set `default-src` as fallback", "Generate a cryptographically random nonce", "Always set", "Never reuse nonces" |
| Examples with I/O | ✅ | 3 examples: Express setup, CSP debugging, production audit — each with clear Input/Output |
| Resources properly linked | ✅ | 3 reference docs, 3 scripts, 5 assets — all linked in tables with descriptions |

**Structure score: 7/7 criteria met.**

---

## B. Content Check

### CSP Directives — ✅ Accurate
- All fetch, document, navigation, and reporting directives correctly listed in SKILL.md and `csp-deep-dive.md`.
- Source values (`'none'`, `'self'`, `'unsafe-inline'`, `'strict-dynamic'`, nonces, hashes) are correct.
- Fallback chain (`worker-src` → `child-src` → `script-src` → `default-src`) is accurate.

### CSP Levels — ✅ Accurate
- **Level 1**: Basic allowlist — correct.
- **Level 2**: nonce, hash, `frame-ancestors`, `base-uri`, `child-src`, `form-action` — correct.
- **Level 3**: `strict-dynamic`, `report-to`, `worker-src`, `manifest-src`, `navigate-to` — **verified correct** per W3C CSP3 Working Draft and MDN.

### HSTS Behavior — ✅ Accurate
- Trust-on-first-use: correctly noted.
- `max-age=31536000` (1 year) as minimum for preload: correct.
- `includeSubDomains` + `preload` requirements: correct.
- Warning about preload removal taking months: accurate (requires browser release cycles).
- Advice to start with short `max-age` during rollout: good practice, correctly stated.

### Cookie Attributes — ✅ Accurate
- `__Host-` prefix: requires `Secure`, `Path=/`, no `Domain` — correct per RFC 6265bis and MDN.
- `__Secure-` prefix: requires `Secure` only — correct.
- `SameSite=None` requires `Secure` — correct.
- Example `Set-Cookie: __Host-session=abc123; Path=/; Secure; HttpOnly; SameSite=Strict` — valid.

### CORP/COEP/COOP — ✅ Accurate
- CORP values (`same-origin`, `same-site`, `cross-origin`): correct.
- COEP values (`require-corp`, `credentialless`): correct. `credentialless` correctly described as less restrictive alternative.
- COOP: `same-origin` correctly stated as requirement for cross-origin isolation.
- `COOP: same-origin` + `COEP: require-corp` → `self.crossOriginIsolated`: correct.
- Enables `SharedArrayBuffer` and high-resolution timers: correct.

### Helmet.js Configs — ✅ Correct (minor note)
- SKILL.md and `helmet-config.ts` use `xFrameOptions: { action: 'deny' }` — this is the Helmet v7+ API (renamed from `frameguard`). Correct for current versions.
- Nonce middleware pattern (generating nonce in earlier middleware, consuming in Helmet middleware via `res.locals.cspNonce`) is the correct pattern.
- Note that Permissions-Policy must be set separately (Helmet doesn't set it) — correctly documented.
- `helmet({...})(req, res, next)` per-request invocation pattern for dynamic nonces — correct.

### Nginx Config — ✅ Correct
- `always` parameter correctly used to apply headers on error responses.
- Warning about nested `location` blocks overriding parent headers — accurate Nginx behavior.
- COEP commented out by default with note about breakage — good practice.
- `server_tokens off` and `proxy_hide_header X-Powered-By` — correct hardening directives.

### No errors found in reference files
- `csp-deep-dive.md`: Comprehensive directives table, nonce/hash patterns, bypass vectors all accurate.
- `framework-configs.md`: 13 framework/platform configs reviewed — patterns are correct.
- `troubleshooting.md`: 9 common issues covered with accurate root causes and fixes.

---

## C. Trigger Check

### Should trigger (✅ all correct):
| Query | Trigger? | Matched keyword |
|---|---|---|
| "Set up CSP for my Express app" | ✅ Yes | CSP, Content-Security-Policy |
| "HSTS not working on subdomains" | ✅ Yes | HSTS, Strict-Transport-Security |
| "Configure Helmet.js security headers" | ✅ Yes | Helmet.js, security headers |
| "Add frame-ancestors to prevent clickjacking" | ✅ Yes | frame-ancestors |
| "Set-Cookie security best practices" | ✅ Yes | Set-Cookie security |
| "Enable SharedArrayBuffer with COEP" | ✅ Yes | COEP, cross-origin isolation |
| "CSP nonce vs hash" | ✅ Yes | nonce, CSP |
| "CSP report-to endpoint" | ✅ Yes | report-to, CSP reporting |

### Should NOT trigger (✅ all correctly excluded):
| Query | Trigger? | Exclusion reason |
|---|---|---|
| "Fix CORS preflight errors" | ✅ No | "CORS preflight debugging" in negative triggers |
| "Set up OAuth2 token flow" | ✅ No | "OAuth/OIDC token handling" excluded |
| "HTTP caching best practices" | ✅ No | "general HTTP caching strategy" excluded |
| "Configure TLS certificates" | ✅ No | "TLS certificate configuration" excluded |
| "Set up WAF rules in Cloudflare" | ✅ No | "WAF configuration" excluded |
| "Cookie consent GDPR banner" | ✅ No | "cookie consent banners" excluded |
| "Rate limiting API endpoints" | ✅ No | "rate limiting headers" excluded |

### Edge cases:
- "General web security hardening" — would likely NOT trigger (no generic "web security" in positive triggers). Acceptable.
- "Prevent XSS attacks" — could arguably trigger due to CSP/nonce coverage, but not explicitly in trigger list. Not a problem since CSP *is* XSS prevention.

**Trigger quality: Strong.** Positive triggers are highly specific. Negative triggers cover adjacent domains well.

---

## D. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 5/5 | All technical claims verified against MDN, W3C spec, and official docs. CSP levels, HSTS, cookies, CORP/COEP/COOP all correct. No factual errors found. |
| **Completeness** | 5/5 | Covers all major security headers (CSP, HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy, CORP/COEP/COOP, Cache-Control, Set-Cookie). 13 framework configs. Troubleshooting guide. 3 scripts. 5 asset files. CSP bypass vectors documented. |
| **Actionability** | 5/5 | Copy-paste configs for every major framework/server. Executable audit script with A-F grading. Interactive CSP generator. CSP report test server. Vitest test suite. All examples have concrete code. |
| **Trigger quality** | 4/5 | Excellent coverage of specific header names, tools, and concepts. Comprehensive negative triggers. Minor: could explicitly exclude "XSS prevention" and "clickjacking" as standalone topics (though these are reasonable triggers since CSP/frame-ancestors are the solutions). |

**Overall: 4.75 / 5.0** ✅

---

## Issues Filed

None required — all dimensions ≥ 3 and overall ≥ 4.0.

---

## Summary

This is an exceptionally well-crafted skill. The SKILL.md body is dense but under the 500-line limit, uses imperative voice throughout, and covers the full security headers landscape with verified accuracy. The reference files provide deep-dive coverage (CSP directives, framework configs, troubleshooting) and the assets deliver production-ready code (Helmet config, Nginx snippet, Next.js middleware, CSP report handler, test suite). The three shell scripts (audit, generate, test) add significant practical value. Trigger specificity is excellent with well-chosen negative boundaries.

**Minor suggestions for future improvement (not blocking):**
1. Consider adding `Trusted-Types` coverage to SKILL.md body (currently only in `csp-deep-dive.md` reference).
2. The 489-line count is very close to the 500-line limit — monitor if content is added.
