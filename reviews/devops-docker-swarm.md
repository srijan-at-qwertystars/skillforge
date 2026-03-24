# QA Review: devops/docker-swarm

**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-16
**Skill path:** `~/skillforge/devops/docker-swarm/`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `docker-swarm` |
| YAML frontmatter has `description` | ✅ Pass | Comprehensive multi-line description |
| Positive triggers listed | ✅ Pass | 13+ positive trigger phrases (swarm init, service create, stack deploy, overlay networks, etc.) |
| Negative triggers listed | ✅ Pass | 6 negative triggers (Kubernetes, standalone Compose, ECS, Nomad, Docker Desktop, containerd/CRI-O) |
| SKILL.md body under 500 lines | ✅ Pass | 489 lines (just under limit) |
| Imperative voice | ✅ Pass | Uses imperative consistently ("Initialize a swarm", "Specify `--advertise-addr`", "Deploy exactly one task") |
| Examples present | ✅ Pass | Extensive CLI and YAML examples throughout |
| Resources linked from SKILL.md | ✅ Pass | References, Scripts, and Assets sections all link to supporting files |
| References directory populated | ✅ Pass | `advanced-patterns.md` (714 lines), `troubleshooting.md` (771 lines) |
| Scripts directory populated | ✅ Pass | 3 executable scripts with usage docs |
| Assets directory populated | ✅ Pass | 2 production-ready stack templates |

**Structure verdict:** Pass — well-organized, all required elements present.

---

## B. Content Check

### Verified Claims (Web Search)

| Claim | Status | Source |
|-------|--------|--------|
| Swarm ports: TCP 2377, TCP/UDP 7946, UDP 4789 | ✅ Correct | Docker official docs |
| Never exceed 7 managers | ✅ Correct | Docker official recommendation |
| Raft consensus requires odd number of managers | ✅ Correct | Docker admin guide |
| Manager quorum table (3→2, 5→3, 7→4) | ✅ Correct | Matches Docker docs |
| `docker swarm ca --rotate` syntax | ✅ Correct | Docker CLI reference |
| `docker swarm update --autolock=true` syntax | ✅ Correct | Docker CLI reference |
| `docker service update --network-add` syntax | ✅ Correct | Docker CLI reference |
| Traefik v3 uses `--providers.swarm` (not `--providers.docker.swarmMode`) | ✅ Correct | Traefik v3 migration docs confirm the new provider name |

### Issues Found

#### Issue 1: `version: "3.8"` is deprecated (Minor)
- **Location:** SKILL.md line 113, `assets/docker-stack.yml` line 13, `assets/traefik-stack.yml` line 18
- **Problem:** The `version` field in Compose files is deprecated in Docker Compose V2 and ignored. Including it generates a deprecation warning. While it doesn't break functionality, a production-ready skill should use modern syntax.
- **Fix:** Remove `version: "3.8"` lines, or add a note that the field is deprecated and optional.

#### Issue 2: Dead code in `init-swarm.sh` — unreachable `$?` check (Minor)
- **Location:** `scripts/init-swarm.sh` lines 78–81
- **Problem:** The script uses `set -euo pipefail` (line 17). If `docker swarm init` fails, the script exits immediately. The `if [[ $? -ne 0 ]]` check on line 78 is unreachable dead code — `$?` will always be 0 at that point.
- **Fix:** Remove the dead check, or use `if ! docker swarm init ...; then` pattern instead.

#### Issue 3: Redis healthcheck in `docker-stack.yml` uses unresolvable `$(...)` (Bug)
- **Location:** `assets/docker-stack.yml` lines 207–210
- **Problem:** The healthcheck `test: ["CMD", "redis-cli", "-a", "$(cat /run/secrets/redis_password)", "ping"]` uses exec-form array syntax, where `$(...)` shell expansion does **not** occur. The literal string `$(cat /run/secrets/redis_password)` is passed as the password argument, which will always fail authentication.
- **Fix:** Use shell form: `test: ["CMD-SHELL", "redis-cli -a $(cat /run/secrets/redis_password) ping"]`

#### Issue 4: Missing gotcha — Docker Swarm deprecation/maintenance status (Minor)
- **Location:** SKILL.md (missing)
- **Problem:** Docker Swarm is no longer actively developed by Docker Inc. (handed to Mirantis). The skill should mention this context so users can make informed decisions about adopting Swarm vs. alternatives. The references mention a "Swarm vs Kubernetes Decision Matrix" but the main SKILL.md doesn't note Swarm's maintenance status.
- **Fix:** Add a brief note about Swarm's current maintenance status near the top or in a "Considerations" section.

#### Issue 5: `deploy-stack.sh` external secrets parsing is fragile (Minor)
- **Location:** `scripts/deploy-stack.sh` lines 152–156
- **Problem:** The grep-based YAML parsing for external secrets/networks is brittle and may produce false positives or miss entries depending on YAML formatting. This is acknowledged as a limitation of shell-based YAML parsing but worth noting.
- **Fix:** Consider documenting this limitation or using `docker compose config` output for more reliable parsing.

---

## C. Trigger Check

### Description trigger quality

The description is well-crafted with specific, actionable trigger phrases:
- **Positive triggers** cover the major Swarm concepts: `swarm init`, `service create`, `stack deploy`, `overlay networks`, `rolling updates`, `swarm secrets`, `ingress routing mesh`, `manager/worker nodes`, `service discovery in swarm`.
- **Negative triggers** correctly exclude Kubernetes, standalone Compose, ECS, Nomad, Docker Desktop, and container runtimes without swarm context.

### Potential false triggers

| Scenario | Risk | Assessment |
|----------|------|------------|
| User mentions "Docker service" in non-Swarm context | Low | "docker service create" is Swarm-specific; unlikely false trigger |
| User asks about "overlay networks" in Kubernetes | Very Low | Negative trigger for k8s should prevent this |
| User asks about Docker Compose with `deploy:` key on single host | Low | Negative trigger for "standalone Docker Compose on a single host" covers this, though edge cases exist |
| User mentions "container orchestration" generically | Low | Description requires Swarm-specific terms, not generic orchestration |

### Missing triggers

- Could add: `docker node update`, `docker stack`, `swarm join`, `swarm leave` as explicit positive triggers.
- Could add negative trigger for: `Docker Kubernetes` (Docker Desktop's built-in K8s).

**Trigger verdict:** Good — specific enough to avoid most false triggers, comprehensive positive coverage.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All core claims verified correct. Redis healthcheck bug in asset template is the only factual error. Deprecated `version` field is a minor accuracy issue. |
| **Completeness** | 4 | Excellent coverage of Swarm topics. Missing Swarm deprecation/maintenance status context. Reference docs are thorough (1,485 lines combined). |
| **Actionability** | 5 | Outstanding — imperative voice, copy-paste-ready examples, production templates, operational scripts with pre-flight checks, troubleshooting checklists. |
| **Trigger Quality** | 4 | Well-targeted positive and negative triggers. Minor gaps in edge case coverage. |
| **Overall** | **4.25** | High-quality skill with minor issues. |

---

## E. Issues Summary

| # | Severity | Issue | Action |
|---|----------|-------|--------|
| 1 | Minor | `version: "3.8"` deprecated in Compose V2 | Update templates |
| 2 | Minor | Dead code `$?` check in `init-swarm.sh` | Remove or restructure |
| 3 | Bug | Redis healthcheck `$(...)` won't expand in exec-form | Switch to CMD-SHELL form |
| 4 | Minor | Missing Swarm deprecation/maintenance status note | Add context |
| 5 | Minor | Fragile YAML parsing in `deploy-stack.sh` | Document limitation |

---

## F. Verdict

**Status: PASS**

Overall score 4.25 ≥ 4.0 and no dimension ≤ 2. No GitHub issues required.
Skill marked as `<!-- tested: pass -->`.
