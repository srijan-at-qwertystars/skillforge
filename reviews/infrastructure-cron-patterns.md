# QA Review: infrastructure/cron-patterns

**Reviewer:** Copilot CLI  
**Date:** 2025-07-16  
**Skill path:** `~/skillforge/infrastructure/cron-patterns/`  
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `cron-patterns` |
| YAML frontmatter `description` | ✅ | Multi-line, detailed |
| Positive triggers | ✅ | 11 trigger phrases: cron job setup, scheduled tasks, crontab syntax, periodic job execution, cron expressions, cron debugging, crontab management, cron output handling, cron security, cron in containers, cron monitoring |
| Negative triggers | ✅ | 3 exclusions: systemd timers, CI/CD pipelines, app-level schedulers (Celery/Bull/Sidekiq) |
| Body under 500 lines | ✅ | 498 lines |
| Imperative voice | ✅ | Mostly imperative ("Use," "Set," "Check," "Always use absolute paths"). Some declarative reference-style prose is appropriate for a cheatsheet/reference skill. |
| Examples with I/O | ✅ | Abundant code blocks with inline comments explaining behavior. Diagnostic flowchart. Validator script shows next N runs. |
| References linked from SKILL.md | ✅ | Table links to `references/advanced-patterns.md`, `references/troubleshooting.md` |
| Scripts linked from SKILL.md | ✅ | Table links to `scripts/cron-validator.sh`, `scripts/cron-wrapper.sh`, `scripts/cron-monitor.sh` |
| Assets linked from SKILL.md | ✅ | Table links to `assets/crontab-templates.md`, `assets/cron-expression-cheatsheet.md`, `assets/k8s-cronjob.yaml` |

**Structure verdict:** All criteria met. Well-organized with clear section hierarchy.

---

## B. Content Check

### Facts Verified via Web Search

| Claim | Verified | Source |
|-------|----------|--------|
| DOM + DOW are ORed when both non-`*` | ✅ Correct | man 5 crontab, Stack Overflow, Linuxize |
| `%` is treated as newline/stdin delimiter in crontab | ✅ Correct | man 5 crontab, Stack Overflow |
| `3/15` in minute field → 3, 18, 33, 48 | ✅ Correct | crontab.guru, multiple sources |
| `0` and `7` both represent Sunday | ✅ Correct | POSIX standard |
| `@weekly` = `0 0 * * 0` | ✅ Correct | man 5 crontab |
| DST spring-forward skips jobs in skipped hour | ✅ Correct | Multiple cron references |
| Standard Unix cron supports only `*`, `,`, `-`, `/` | ✅ Correct | `L`, `W`, `#`, `?` are Quartz extensions |

### Gotchas Coverage

| Gotcha | Covered | Location |
|--------|---------|----------|
| `%` escaping | ✅ | SKILL.md §Critical Gotchas, troubleshooting.md |
| DOM+DOW OR logic | ✅ | SKILL.md §Critical Gotchas, advanced-patterns.md |
| Trailing newline required | ✅ | SKILL.md §Other gotchas |
| Minimal PATH in cron | ✅ | SKILL.md §Environment Variables, troubleshooting.md |
| User vs system crontab format | ✅ | SKILL.md §Other gotchas, troubleshooting.md |
| `crontab -r` danger | ✅ | troubleshooting.md §Common Mistakes |
| DST transitions | ✅ | troubleshooting.md §DST Transitions |
| `~` expansion issues | ✅ | troubleshooting.md §Common Mistakes |
| Locale-dependent output | ✅ | troubleshooting.md §Common Mistakes |
| Container env var loss | ✅ | SKILL.md §Cron in Containers, troubleshooting.md |
| `cron.allow`/`cron.deny` precedence | ✅ | SKILL.md §Cron Security |

### Issues Found

1. **Minor inaccuracy — `%` description (SKILL.md line 429):** States "% is treated as newline, breaks the command." More precisely, the first unescaped `%` marks the end of the shell command; everything after is sent to stdin with `%` replaced by newlines. The practical advice (escape with `\%`) is correct. The troubleshooting.md correctly says "Command truncated at first `%`."

2. **Bug — "Every 45 minutes" pattern (advanced-patterns.md lines 129–132):** The three crontab entries shown are incorrect. Line 1 (`0,45 * * * *`) fires at :00 and :45 of **every** hour, producing 48 runs/day instead of the expected 32. Correct entries would restrict hours:
   ```
   0,45 0,3,6,9,12,15,18,21 * * *
   30 1,4,7,10,13,16,19,22 * * *
   15 2,5,8,11,14,17,20,23 * * *
   ```
   The "every 90 minutes" pattern directly above it is correct.

3. **Missing gotcha:** No explicit mention that `*/45` in the minute field fires at minutes 0 and 45 (not a true 45-minute interval). This is a common user mistake worth calling out.

---

## C. Trigger Check

### Description Quality

The description is detailed and "pushy" — it lists 11 positive trigger scenarios and 3 clear exclusions. The keyword coverage is strong for discoverability.

| Aspect | Assessment |
|--------|-----------|
| Positive trigger breadth | ✅ Strong — covers syntax, debugging, management, security, containers, monitoring |
| Negative trigger clarity | ✅ Clear — systemd timers, CI/CD pipelines, app-level schedulers explicitly excluded |
| False positive risk | Low — "scheduled tasks" could match Windows Task Scheduler, but context disambiguates |
| False negative risk | Low — comprehensive keyword set covers most cron-related queries |
| Cross-reference quality | ✅ Points to `systemd-services` skill for systemd timers |

### Potential Improvements

- Consider adding negative trigger: "NOT for Windows Task Scheduler"
- Consider adding negative trigger: "NOT for `at`/`batch` one-time scheduling"

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All SKILL.md facts verified correct. One incorrect example in `references/advanced-patterns.md` (every-45-minutes pattern). Minor simplification of `%` behavior in SKILL.md (correct in troubleshooting.md). |
| **Completeness** | 5 | Exceptionally thorough. Covers Unix syntax, Quartz extensions, crontab management, environment, output handling, debugging, systemd comparison, anacron, security, timezone/DST, overlap prevention, containers (Docker + K8s), monitoring, cloud platforms (AWS, GCP). Three utility scripts, three asset templates, two reference docs. |
| **Actionability** | 5 | Excellent. Production-ready copy-paste templates, diagnostic flowchart, wrapper script with logging/locking/healthchecks, validator script, monitor script. K8s CronJob template with inline decision documentation. |
| **Trigger quality** | 4 | Strong positive and negative triggers with good keyword coverage. Slightly verbose description but appropriate for the topic breadth. Minor gaps in negative triggers. |

### Overall Score: **4.5 / 5.0**

---

## E. Issue Filing

Overall score (4.5) ≥ 4.0 and no dimension ≤ 2. **No GitHub issues required.**

### Recommended Fixes (non-blocking)

1. **Fix every-45-minutes pattern** in `references/advanced-patterns.md` (lines 129–132) — restrict hour fields to produce exactly 32 runs/day.
2. **Clarify `%` behavior** in SKILL.md line 429 — change "treated as newline" to "truncates command; remainder sent as stdin."
3. **Add `*/45` gotcha** — note that `*/N` where N doesn't divide 60 evenly resets each hour.

---

## F. Test Marker

Appended `<!-- tested: pass -->` to SKILL.md.

---

*Review path: `~/skillforge/reviews/infrastructure-cron-patterns.md`*
