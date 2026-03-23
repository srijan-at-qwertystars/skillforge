# Skill Review: containerd-nerdctl

**Path:** `~/skillforge/devops/containerd-nerdctl/`
**Reviewer:** QA (automated)
**Date:** 2025-01-21

---

## (a) Structure

| Criterion | Status | Notes |
|---|---|---|
| Frontmatter name | ✅ Pass | `containerd-nerdctl` |
| Frontmatter description | ✅ Pass | Comprehensive with positive triggers (containerd, nerdctl, CRI, BuildKit, snapshotter, etc.) and negative triggers (Docker Engine, Docker Swarm, Podman, CRI-O) |
| Body line count | ⚠️ Borderline | Exactly 500 lines (requirement: under 500). At the boundary. |
| Imperative voice | ✅ Pass | Commands and instructions use imperative voice throughout |
| Examples | ✅ Pass | Rich, runnable examples for every section — CLI commands, config snippets, troubleshooting |
| Resources linked | ✅ Pass | References (3), Scripts (3), Assets (4) all linked and described in Resources section |

### Structural Issues

1. **Markdown formatting bug on line 103–104:** `## Image Management``` bash` — heading and fenced code block are joined on the same line with no blank line between them. This will render incorrectly in most Markdown processors.

---

## (b) Content Verification

### Claims verified via web search

| Claim | Verdict | Detail |
|---|---|---|
| nerdctl latest = v2.2.1 | ✅ Correct | Confirmed as current stable release (Dec 2025) |
| containerd config `version = 3` for 2.x | ✅ Correct | Required for containerd 2.x per official docs |
| `containerd config migrate` command | ✅ Correct | Prints migrated config in v3 format |
| `nerdctl checkpoint create` support | ✅ Correct | Supported; requires CRIU (not mentioned in skill — minor gap) |
| Default config path `/etc/containerd/config.toml` | ✅ Correct | Standard location |
| `SystemdCgroup = true` needed for cgroup v2 | ✅ Correct | Well-documented requirement |
| CNI plugins in `/opt/cni/bin/` | ✅ Correct | Standard location |
| `nerdctl compose` Docker Compose compatible | ✅ Correct | Uses docker-compose.yaml directly |

### Inaccuracies Found

1. **SKILL.md line 275 — compose configs/secrets claim is wrong.**
   The skill states: *"Not supported: deploy, configs, secrets (Swarm-only features)."*
   - **configs and secrets ARE supported** in nerdctl compose (file-based mounting as read-only). Only `external:` configs/secrets are unsupported.
   - **deploy is partially supported** — `deploy.resources.limits` (memory, cpus) works. What's unsupported are `update_config`, `rollback_config`, `placement`, `endpoint_mode`.
   - The skill's own `nerdctl-compose.yml` asset uses `deploy.resources.limits` — directly contradicting this claim.

2. **Checkpoint/restore syntax incomplete.** The skill shows `nerdctl start --checkpoint checkpoint1 web` for restore, but omits the CRIU dependency requirement, which is a critical prerequisite.

3. **Install script version mismatch.** `containerd-install.sh` hardcodes containerd 2.0.4, while SKILL.md examples reference the nerdctl-full bundle with 2.2.1. Not strictly wrong (components are installed independently) but could confuse users.

### Missing Gotchas

- **CRIU required for checkpoint/restore** — not mentioned anywhere in the skill.
- **`nerdctl pull` defaults require fully qualified image names** — mentioned only in troubleshooting reference, not in main SKILL.md pull examples (e.g., `nerdctl pull nginx:alpine` works via Docker Hub default but this differs from raw containerd/ctr behavior).
- **containerd 2.x removed dockershim** — worth mentioning for migration context.

---

## (c) Trigger Analysis

| Scenario | Should Trigger? | Would Trigger? | Result |
|---|---|---|---|
| "install containerd" | Yes | Yes — matches `containerd` keyword | ✅ |
| "configure nerdctl" | Yes | Yes — matches `nerdctl` keyword | ✅ |
| "set up rootless containers with containerd" | Yes | Yes — matches `containerd`, `rootless containers` | ✅ |
| "configure CRI runtime for Kubernetes" | Yes | Yes — matches `CRI`, `container runtime` | ✅ |
| "install Docker" | No | No — excluded by negative triggers | ✅ |
| "Docker Swarm setup" | No | No — excluded by negative triggers | ✅ |
| "configure Podman" | No | No — excluded by negative triggers | ✅ |
| "CRI-O installation" | No | No — excluded by negative triggers | ✅ |
| "Kubernetes cluster admin" | No | No — excluded for general K8s admin | ✅ |
| "Docker Desktop troubleshooting" | No | No — excluded by negative triggers | ✅ |

**Trigger assessment:** Well-constructed. Positive triggers are specific and comprehensive. Negative triggers properly exclude Docker-specific, Podman, and CRI-O scenarios. No false-positive risk identified.

---

## (d) Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 3 | Compose configs/secrets claim is factually wrong and self-contradicted by the compose asset. Markdown formatting bug on line 103–104. Missing CRIU prerequisite for checkpoint. |
| **Completeness** | 5 | Exceptional coverage: installation, CLI mapping, config, networking, storage, rootless, compose, registry, content trust, CRI/K8s integration, ctr/nerdctl/crictl comparison, lazy pulling, debugging, migration, anti-patterns. Three reference docs, three scripts, four asset files. |
| **Actionability** | 5 | Highly actionable — every section has copy-paste commands, working config snippets, troubleshooting with causes and fixes. Scripts are production-ready with error handling, flags, and verification steps. |
| **Trigger Quality** | 4 | Strong positive/negative trigger separation. Could add a few more negative triggers (e.g., LXC/LXD, rkt) but current set covers the main confusion points well. |

### Overall Score: **4.25 / 5**

---

## Required Fixes

1. **Fix line 103–104:** Add newline between `## Image Management` heading and the code fence.
2. **Fix line 275:** Correct the compose compatibility statement. Replace *"Not supported: deploy, configs, secrets (Swarm-only features)"* with accurate information about what is/isn't supported.
3. **Add CRIU note** to the checkpoint/restore section (line 138–141).

## Recommended Improvements

- Align install script containerd version (2.0.4) closer to latest stable (2.2.1) or add a note about checking for latest versions.
- Add a note about fully qualified image names in the Image Management section.
- Consider trimming 1–2 lines to get strictly under 500.

---

**Verdict:** `needs-fix` — Factual inaccuracy in compose feature support requires correction before the skill can pass QA.
