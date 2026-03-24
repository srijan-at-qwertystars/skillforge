# Review: nginx-config

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Deprecated `listen ... http2` syntax (Accuracy)**: SKILL.md (lines 58–59, 336) and
   `assets/reverse-proxy.conf` (lines 43–44) use `listen 443 ssl http2;` which is deprecated
   since nginx 1.25.1. Modern syntax is `listen 443 ssl;` + `http2 on;` as a separate directive.
   The old syntax still works but emits warnings on nginx ≥1.25.1.

2. **Missing `add_header_inherit` mention**: The skill correctly documents the `add_header`
   inheritance pitfall but doesn't mention the `add_header_inherit merge;` directive available
   in nginx 1.29.3+ that resolves it natively without `include` workarounds.

## Structure Check

- ✅ YAML frontmatter: `name` and `description` present
- ✅ Positive triggers: nginx config, reverse proxy, load balancing, SSL/TLS, virtual hosts,
  upstream, rate limiting, caching, gzip, security hardening, HTTP/2-3, WebSocket, API gateway,
  location blocks, rewrite rules, try_files, error pages, worker tuning, debugging
- ✅ Negative triggers: Apache/Caddy/Traefik/HAProxy, app-level routing, DNS, firewall, k8s
- ✅ Body: 484 lines (under 500 limit)
- ✅ Imperative voice throughout ("Generate…", "Validate with…", "Use…")
- ✅ Input → Output examples section with 4 examples
- ✅ References linked: 3 reference docs (advanced-patterns, troubleshooting, security-hardening)
- ✅ Scripts linked: 3 scripts (ssl-setup, config-test, log-analyzer), all with usage docs
- ✅ Assets linked: 4 config templates (reverse-proxy, ssl-params, rate-limiting, security-headers)

## Content Check (Web-Verified)

- ✅ Location matching priority order (=, ^~, ~, ~*, prefix) — verified correct
- ✅ `proxy_pass` trailing slash URI stripping behavior — verified correct
- ✅ `limit_req_zone` 10m ≈ 160,000 IPs — verified correct (16k IPs/MB × 10MB)
- ✅ `add_header` child-replaces-parent inheritance — verified correct
- ✅ SSL cipher suites use ECDHE-only for forward secrecy — correct modern practice
- ✅ `ssl_prefer_server_ciphers off` for TLS 1.3 — correct modern recommendation
- ✅ `worker_rlimit_nofile ≥ 2× worker_connections` — correct guidance
- ✅ "If is evil" pitfall with safe uses (return, rewrite, variable assignment) — correct
- ✅ WebSocket proxy requires `proxy_http_version 1.1` + Upgrade/Connection headers — correct
- ✅ gRPC requires `grpc_pass` not `proxy_pass` — correct
- ⚠️ `listen 443 ssl http2;` deprecated since nginx 1.25.1 (see Issue #1)
- ⚠️ `add_header_inherit merge;` not mentioned (see Issue #2)

## Trigger Check

- ✅ Description is comprehensive — covers 20+ trigger keywords
- ✅ Negative triggers clearly scoped: 5 explicit NOT-for exclusions
- ✅ No obvious false trigger vectors — well-bounded to nginx-specific tasks
- ✅ Would correctly trigger on edge cases like "WebSocket proxying" or "nginx as API gateway"

## Assessment

Excellent skill with deep, accurate content. The only material issue is the deprecated
`listen ... http2` syntax which affects users on nginx 1.25.1+ (released July 2023). All
other directives, default values, and examples are verified correct. The references, scripts,
and assets are production-quality. An AI would execute configs correctly with the caveat of
deprecation warnings on modern nginx.
