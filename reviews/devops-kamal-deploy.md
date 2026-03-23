# Review: kamal-deploy

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.3/5

## Structure Check

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (Kamal, kamal-proxy, deploy.yml, MRSK, zero-downtime, Rails 8, rollback, .kamal/secrets) AND negative triggers (Kubernetes, Docker Compose, Helm, Terraform, Ansible, ECS/Fargate)
- ✅ Body is 488 lines (under 500)
- ✅ Imperative voice, no filler — concise and direct throughout
- ✅ Examples with input/output (Rails 8 on DigitalOcean, rollback, Sidekiq worker)
- ✅ references/ and scripts/ properly linked from SKILL.md with descriptive tables
- ✅ assets/ linked with descriptions

## Content Check — Accuracy

**Verified correct:**
- `proxy:` block format with `ssl`, `host`, `app_port`, `healthcheck` (path/interval/timeout), `response_timeout`, `forward_headers` — all match official docs at kamal-deploy.org
- CLI commands `kamal deploy`, `kamal redeploy`, `kamal rollback`, `kamal app exec`, `kamal proxy reboot`, `kamal proxy details`, `kamal proxy logs` — confirmed accurate
- kamal-proxy replaces Traefik, runs on ports 80/443, default app_port is 80 — correct
- `.kamal/secrets`, `.kamal/secrets-common`, `.kamal/secrets.staging` file structure — correct
- Health check must return HTTP 200, deploy fails on timeout, old container keeps serving — correct
- `kamal setup` for first deploy, `kamal deploy` for subsequent — correct
- Let's Encrypt via `ssl: true` with ACME HTTP-01 challenge — correct
- Multi-app routing via Host header in kamal-proxy — correct

**Minor accuracy concerns:**
- `kamal proxy reboot --rolling` flag (advanced-patterns.md line 264): not confirmed in official docs; may not exist
- `kamal lock release --force` (troubleshooting.md line 391): `--force` flag not confirmed in official docs
- `kamal server bootstrap` (SKILL.md line 177): may not exist as a standalone command; `kamal setup` handles server bootstrapping
- `ssl_certificate_path` in advanced-patterns.md (line 457): official docs use `ssl.certificate_pem` / `ssl.private_key_pem` instead
- Secrets file examples show hardcoded values (`KAMAL_REGISTRY_PASSWORD=ghp_xxx`), which works but Kamal 2 now recommends `kamal secrets fetch` / `kamal secrets extract` pattern with adapter-based secret management

## Content Check — Completeness

**Well covered:**
- deploy.yml full reference, proxy config, accessories, secrets, hooks, CI/CD, SSL, health checks, asset bridging, multi-server roles, destinations, builder config
- Troubleshooting guide is thorough (container failures, health checks, SSH, registry, proxy, locks, accessories, SSL, debug commands)
- Production checklist covers pre-deploy, server hardening, monitoring, backups, secrets rotation, rollback
- Advanced patterns cover blue-green, canary, multi-app, migrations, multi-arch builds

**Missing items:**
- No mention of **Thruster** — Rails 8 ships with Thruster (HTTP proxy on port 80), which changes port configuration. Since the skill triggers for "Rails 8 deployment", this is a notable gap
- Missing `drain_timeout` and `readiness_delay` configuration options, which affect zero-downtime behavior
- No mention of `kamal secrets fetch` / `kamal secrets extract` — the new recommended secrets workflow for Kamal 2
- No mention of **Kamal 1 → 2 upgrade path** (important since many users migrating)
- Docker Swarm not listed in negative triggers (edge case false trigger risk)

## Trigger Check

- ✅ "deploy Rails app" — would trigger via "Rails 8 deployment" and "Kamal" references
- ✅ "zero-downtime deployment" — matches "zero-downtime container deploys"
- ✅ "Kamal setup" — direct match on "Kamal"
- ✅ Would NOT trigger for Kubernetes — explicitly excluded
- ✅ Would NOT trigger for Docker Compose standalone — explicitly excluded
- ✅ Would NOT trigger for Helm/Terraform/Ansible/ECS — explicitly excluded
- ⚠️ Docker Swarm not explicitly in negative triggers — minor false trigger risk

## Issues

1. **Unverified CLI flags**: `--rolling` on `kamal proxy reboot`, `--force` on `kamal lock release`, and `kamal server bootstrap` are not confirmed in official Kamal 2 docs. Could mislead users if they don't exist.
2. **Missing Thruster/Rails 8 port gotcha**: Rails 8 defaults to Thruster which listens on port 80. The skill's examples all use `app_port: 3000`, which may be wrong for default Rails 8 setups. This is especially relevant since "Rails 8 deployment" is a trigger.
3. **Outdated secrets pattern**: The skill shows direct key=value secrets but doesn't cover `kamal secrets fetch`/`kamal secrets extract`, which is the recommended Kamal 2 approach.
4. **`ssl_certificate_path` may be inaccurate**: Advanced patterns reference shows this option, but official docs use `ssl.certificate_pem`/`ssl.private_key_pem`.
5. **Missing `drain_timeout`/`readiness_delay`**: Important proxy config options not documented.

## Verdict

**PASS** — High-quality skill with comprehensive coverage. The deploy.yml format, core commands, proxy configuration, and deployment workflow are accurate. Supporting materials (references, scripts, assets) are thorough and production-ready. Issues are minor (unverified flags, missing Thruster mention, secrets pattern update needed) and don't prevent effective use.
