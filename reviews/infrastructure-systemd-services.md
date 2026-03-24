# QA Review: systemd-services

**Skill path:** `~/skillforge/infrastructure/systemd-services/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Reviewer:** Copilot CLI (automated QA)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `systemd-services` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers in description | ✅ Pass | 7 trigger phrases: unit files, service config, timer scheduling, socket-activated daemons, process supervision, journalctl, systemctl operations |
| Negative triggers in description | ✅ Pass | 5 exclusions: Docker, init.d/SysVinit, macOS launchd, Windows services/NSSM, supervisord/pm2 |
| Body under 500 lines | ✅ Pass | 442 lines |
| Imperative voice | ✅ Pass | "Place system units in…", "Run systemctl daemon-reload…", "Use notify if supported…" |
| Examples with Input/Output | ✅ Pass | 5 examples with `# Input:` / `# Output:` comments (oneshot, socket, timer, path, template) |
| References linked from SKILL.md | ✅ Pass | 3 reference docs listed with descriptions (lines 428-431) |
| Scripts linked from SKILL.md | ✅ Pass | 3 scripts listed with descriptions (lines 433-436) |
| Templates linked from SKILL.md | ✅ Pass | 6 template files listed (lines 438-442) |

**Structure verdict:** All structural requirements met.

---

## B. Content Check

### Verified Against Upstream Documentation

| Claim | Verified | Source |
|-------|----------|--------|
| 7 service types (simple, exec, forking, oneshot, notify, dbus, idle) | ✅ Correct | freedesktop.org systemd.service(5) |
| `simple` is default Type | ✅ Correct | freedesktop.org |
| `forking` requires PIDFile | ✅ Correct | All sources confirm |
| `ProtectSystem=yes` → `/usr`,`/boot` ro | ✅ Correct | linux-audit.com (also `/efi`, not mentioned—minor) |
| `ProtectSystem=full` → adds `/etc` ro | ✅ Correct | freedesktop.org, linux-audit.com |
| `ProtectSystem=strict` → entire fs ro | ✅ Correct | freedesktop.org |
| Restart policy values & behavior | ✅ Correct | freedesktop.org systemd.service(5) |
| `MemoryDenyWriteExecute` breaks JIT (Node.js, Java) | ✅ Correct | linux-audit.com, GitHub issues |
| Socket activation fd 3, `$LISTEN_FDS` | ✅ Correct | freedesktop.org sd_listen_fds(3) |
| `systemd-analyze security` scoring 0-10 | ✅ Correct | Verified |

### Factual Issues Found

1. **Exit code 200 description is incorrect** (SKILL.md line 375)
   - **Skill says:** "200 (PrivateTmp/ProtectSystem unsupported)"
   - **Actual:** Exit code 200 = `CHDIR` — `WorkingDirectory=` doesn't exist or can't be accessed
   - **Severity:** Medium. This will mislead users debugging service failures.

2. **Missing `on-success` restart policy** (SKILL.md line 86-95)
   - The Restart= table omits `on-success` (restart only on clean exit code 0). Minor since rarely used, but the table implies completeness.

3. **Production example uses `Type=notify` for Node.js** (line 389)
   - Standard Node.js doesn't call `sd_notify()`. Using `Type=notify` without the `sd-notify` npm package or a wrapper will cause the service to time out at startup. Should note this requires application-side integration or default to `Type=simple`.

### Missing Gotchas (nice-to-have)

- No mention of `ExecStartPre=-` (dash prefix to ignore failures)
- No mention of `systemd-tmpfiles` for volatile/temporary file management
- Doesn't note that `ProtectSystem=yes` also covers `/efi` (minor)
- No mention of `SuccessExitStatus=` for services with non-standard success codes

### Examples Correctness

- All `.ini` unit file examples are syntactically valid
- Timer OnCalendar expressions are correct
- Socket activation examples correctly show `Accept=no` vs `Accept=yes` patterns
- Template specifier table is accurate
- Security hardening progressive levels are well-organized

---

## C. Trigger Check

| Aspect | Assessment |
|--------|------------|
| **Description specificity** | Excellent. Lists 7 concrete positive triggers covering the full systemd surface area |
| **Negative triggers** | Well-chosen. Covers the major confusion points (Docker, init.d, launchd, Windows, supervisord/pm2) |
| **False positive risk** | Low. Generic terms like "service" are qualified with systemd-specific context |
| **False negative risk** | Low. Covers unit files, timers, sockets, paths, journalctl, systemctl |
| **Pushy enough?** | Yes. The description is assertive and comprehensive without being overly broad |
| **Missing negative trigger?** | Could add "NOT for Kubernetes pod specs" or "NOT for cloud-init" but these are edge cases |

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | One factual error (exit code 200), one misleading pattern (Type=notify for Node.js). All other directives, values, and behaviors verified correct. |
| **Completeness** | 5 | Exceptional coverage: unit anatomy, all service types, restart policies, env vars, security hardening (3 tiers), resource limits, socket activation, timers, path units, templates, drop-ins, user services, systemctl/journalctl reference, debugging workflow. 3 reference docs, 3 scripts, 6 templates. |
| **Actionability** | 5 | Copy-paste-ready examples with I/O annotations, progressive hardening checklist, interactive generator script, security audit script, monitoring script, and full template set. Production-ready example included. |
| **Trigger quality** | 5 | Clear, specific positive and negative triggers. Well-scoped to systemd domain without over-triggering. |
| **Overall** | **4.75** | Weighted average. Excellent skill that is nearly production-perfect. Two content fixes needed. |

---

## E. Issue Filing

- **Overall score (4.75) ≥ 4.0:** No issues required by threshold.
- **No dimension ≤ 2:** No issues required by dimension floor.
- **Recommendation:** Fix the two factual issues in a maintenance pass. No blocking issues.

---

## F. Tag Applied

`<!-- tested: pass -->` appended to SKILL.md.

---

## Summary

This is a **high-quality, comprehensive skill** that covers the full systemd service management surface area. The structure is clean, examples are actionable with I/O annotations, and the supporting reference docs, scripts, and templates add significant value. The two content issues (exit code 200 description and Type=notify for Node.js) should be corrected but are not blocking. The trigger description is well-tuned with appropriate positive and negative scoping.

**Result: PASS**
