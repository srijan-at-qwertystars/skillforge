# Review: caddy-server

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: none

## Details

### Structure
- YAML frontmatter: `name` and `description` present. ✓
- Description has positive triggers (Caddy, Caddyfile, caddy reverse proxy, ACME, xcaddy, etc.) AND negative triggers (Nginx, Apache, Traefik, HAProxy, generic TLS/DNS). ✓
- Body: 495 lines — under 500-line limit. ✓
- Imperative voice, no filler throughout. ✓
- Extensive examples with input/output across all sections. ✓
- `references/` (3 files) and `scripts/` (3 files) and `assets/` (5 files) all linked via tables in the Resources section. ✓

### Content Accuracy (web-verified)
- Current stable version "v2.11.x" confirmed — v2.11.2 is latest stable per GitHub releases.
- Caddyfile syntax, block structure, address formats all match official docs.
- Automatic HTTPS via ACME (Let's Encrypt + ZeroSSL fallback) confirmed accurate.
- Directive names (`reverse_proxy`, `file_server`, `encode`, `php_fastcgi`, `handle`, `handle_path`, `try_files`, `basicauth`, `tls`, `log`) all correct.
- `lb_policy` values (`round_robin`, `least_conn`, `random`, `first`, `ip_hash`, `uri_hash`, `header`, `cookie`) verified.
- Module paths (`caddy-dns/cloudflare`, `mholt/caddy-ratelimit`, `greenpau/caddy-security`) correct.
- Admin API on `:2019`, `caddy adapt`, `caddy validate` commands correct.
- Docker image `caddy:2-alpine` and builder `caddy:2-builder-alpine` correct.

### Completeness
- Covers: installation, Caddyfile syntax, auto-HTTPS, reverse proxy, load balancing, static files, middleware, matchers, logging, JSON API, modules/xcaddy, Docker, systemd, PHP/FastCGI, WebSocket, TLS customization, common patterns, anti-patterns.
- References add: advanced patterns (on-demand TLS, CEL matchers, storage backends, Prometheus), troubleshooting (15+ failure scenarios with fixes), Nginx migration (side-by-side translations).
- Scripts: validation, installation, xcaddy build — all well-structured with error handling.
- Assets: 3 production Caddyfile templates, Docker Compose, hardened systemd unit.
- No significant missing gotchas found.

### Actionability
- Copy-pasteable Caddyfile blocks for all common scenarios.
- Production-ready templates in assets/ with security headers, health checks, logging.
- Scripts are executable with proper `set -euo pipefail`, color output, arg parsing.
- Systemd unit has 20+ security hardening directives — ready for production.
- Docker Compose includes networks, secrets, resource limits, health checks.

### Trigger Quality
- "configure Caddy reverse proxy" → matches `Caddy` and `caddy reverse proxy` triggers. ✓
- "configure Nginx" → excluded by DO NOT TRIGGER clause. ✓
- Trigger covers Caddy-specific terms comprehensively without being overly broad.
