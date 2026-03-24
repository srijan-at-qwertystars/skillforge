# QA Review: containers/podman-patterns

**Reviewer:** Copilot CLI  
**Date:** 2025-07-17  
**Skill path:** `containers/podman-patterns/SKILL.md`  
**Lines:** 498 / 500 limit  

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with explicit +/− triggers |
| Under 500 lines | ✅ Pass | 498 lines — just within limit |
| Imperative voice | ✅ Pass | Commands are imperative throughout |
| Examples | ✅ Pass | 4 examples with user-input / output pattern |
| References linked | ✅ Pass | 3 reference files exist and match descriptions |
| Scripts linked | ✅ Pass | 3 scripts, all `chmod +x`, with documented flags |
| Assets linked | ✅ Pass | Quadlet templates, config files, compose template present |

---

## b. Content Check

### Verified accurate (via web search against Podman 5.x docs)

- **Pasta networking** default for rootless in 5.x — ✅ correct
- **Netavark + Aardvark-DNS** replaced CNI — ✅ correct (CNI deprecated)
- **SQLite storage** backend replacing BoltDB — ✅ correct
- **Quadlet syntax** (`.container`, `.pod`, `.volume`, `.network`) — ✅ matches official docs
- **`buildah build`** listed as alias for `buildah bud` — ✅ both are valid aliases
- **Skopeo commands** (`copy`, `sync`, `inspect`, `delete`) — ✅ correct syntax
- **`podman secret create --env`** — ✅ correct; `--env` flag reads value from env var
- **`podman farm build`** — ✅ correct 5.x feature
- **`podman kube play` / `podman kube generate`** — ✅ correct current syntax
- **Auto-update labels and timer** — ✅ correct
- **SELinux `:Z`/`:z` relabeling** — ✅ correct semantics

### Issues found

1. **Bug — Buildah scripted build (line 113)**  
   ```bash
   buildah run $ctr -- microdnf install -y python3 && microdnf clean all
   ```
   The `&& microdnf clean all` runs on the **host**, not inside the container.  
   **Fix:** Use `sh -c` or split into two `buildah run` calls:
   ```bash
   buildah run $ctr -- sh -c "microdnf install -y python3 && microdnf clean all"
   ```

2. **Missing gotcha — cgroup v2 requirement**  
   Podman 5.x deprecates cgroup v1. The SKILL.md doesn't mention this; the
   troubleshooting reference covers it well, but a one-liner in the main doc
   ("Requires cgroup v2; see Troubleshooting for migration") would prevent
   user confusion.

3. **Missing gotcha — cgroup controller delegation for rootless resource limits**  
   Rootless `--cpus`, `--memory` fail without explicit systemd delegation.
   Covered in the troubleshooting reference but not hinted at in the
   Security Hardening section where `--memory 512m --cpus 1.5` is shown.

4. **Minor — `podman system migrate` not in SKILL.md**  
   Essential for 4.x→5.x upgrades. Present in troubleshooting reference only.

---

## c. Trigger Check

| Concern | Assessment |
|---------|-----------|
| Podman-specific positive triggers | ✅ Strong — Podman, podman compose, Quadlet, Buildah, Skopeo, Containerfile, podman farm, podman pod, Netavark, podman machine |
| Docker false-trigger risk | ✅ Low — explicitly excludes Docker Swarm, Docker Desktop licensing |
| containerd/nerdctl overlap | ✅ Low — explicitly excludes "containerd/nerdctl without Podman context" |
| Kubernetes overlap | ✅ Low — excludes "Kubernetes pod management" |
| "rootless containers" ambiguity | ⚠️ Minor — Docker rootless mode exists, but other trigger terms disambiguate |
| Missing negative trigger | ⚠️ Minor — could add "Docker Buildx" and "Docker Compose-only" to negatives |

**Verdict:** Triggers are well-scoped for Podman. False-trigger risk is low.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | One shell bug in Buildah scripted example (host vs container execution). All 5.x facts verified correct. |
| **Completeness** | 4 | Comprehensive main doc. cgroup v2 / migration gotchas covered in references but missing brief mention in SKILL.md. |
| **Actionability** | 5 | Excellent: 4 worked examples, 3 runnable scripts, config templates, quick-reference table, Quadlet templates. |
| **Trigger quality** | 4 | Strong positive/negative scoping. Minor "rootless containers" overlap with Docker rootless. |
| **Overall** | **4.25** | High-quality skill. Fix the Buildah shell bug and add cgroup v2 note for a 4.5+. |

---

## e. Disposition

- **Overall ≥ 4.0**: ✅ Yes (4.25) — no GitHub issue required  
- **Any dimension ≤ 2**: ✅ No — no GitHub issue required  
- **SKILL.md tag**: `<!-- tested: pass -->`

---

## f. Recommended Fixes (non-blocking)

1. Fix `buildah run` command on line 113 to wrap chained commands in `sh -c`.
2. Add a brief cgroup v2 note to the Core Concepts or Rootless section.
3. Add "Docker Buildx" to the negative trigger list in the description.
4. Consider a one-line mention of `podman system migrate` in the Quick Reference table.
