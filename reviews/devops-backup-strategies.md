# QA Review: backup-strategies

**Skill path:** `~/skillforge/devops/backup-strategies/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** PASS (with one bug noted)

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has name | ✅ | `name: backup-strategies` |
| YAML frontmatter has description | ✅ | Multi-line, detailed, 12 lines |
| Positive triggers in description | ✅ | backup setup, disaster recovery, database backup, rsync, restic, borgbackup, snapshot management, backup automation, restore procedures |
| Negative triggers in description | ✅ | NOT for HA/failover, NOT for replication, NOT for version control/git |
| Body under 500 lines | ✅ | 494 lines (just under limit) |
| Imperative voice | ✅ | Consistent ("Maintain 3 copies", "Classify systems", "Automate verification") |
| Examples with I/O | ✅ | Every section has shell examples with inline comments explaining output/effect |
| References linked from SKILL.md | ✅ | 3 reference docs linked with summaries |
| Scripts linked from SKILL.md | ✅ | 3 scripts linked with summaries |
| Assets linked from SKILL.md | ✅ | systemd units, policy template, S3 lifecycle JSON — all linked |

**Structure verdict:** Excellent. Well-organized with clear ToC-like headings, tiered from core principles → tools → automation → monitoring → DR.

---

## b. Content Check

### Commands Verified via Web Search

| Command/Concept | Status | Notes |
|-----------------|--------|-------|
| `restic -r s3:s3.amazonaws.com/bucket backup` | ✅ | Correct S3 URL format per restic docs |
| `restic forget --keep-hourly N --keep-daily N --prune` | ✅ | Valid single command; `--prune` combines forget+prune |
| `borg create --compression zstd,3` | ✅ | Correct syntax; zstd level 3 is default but explicit is good |
| `borg prune` → `borg compact` workflow | ✅ | Correct order: prune then compact to reclaim space |
| `borg init --encryption=repokey-blake2` | ✅ | Valid encryption mode |
| **`pg_dump -Fc -j4`** | ❌ **BUG** | `-j` (parallel) only works with directory format (`-Fd`). With `-Fc` the flag is **silently ignored**. Line 117 is misleading. |
| `pg_restore -j4 -Fc` | ✅ | Parallel restore correctly shown on line 128 |
| `pg_basebackup -Ft -z -P -X stream -c fast` | ✅ | Correct flags |
| S3 lifecycle JSON structure | ✅ | `Rules[]` with `Transitions`, `NoncurrentVersionTransitions`, `Filter.And.Tags` — all valid per AWS API |
| RPO/RTO definitions | ✅ | Accurate: RPO = max data loss (time), RTO = max downtime |
| 3-2-1-1-0 rule | ✅ | Extended rule correctly described |
| `xtrabackup --prepare --incremental-dir` | ✅ | Correct two-phase prepare for incremental |
| `mongodump --oplog` | ✅ | Correct for PITR consistency on replica sets |

### Missing Gotchas

- **pg_dump -Fc -j4 bug** (above) — users will think they get parallel dumps with custom format but they won't.
- No mention of `restic mount` for browsing snapshots (minor — useful for ad-hoc recovery).
- No mention of `borg export-tar` as an alternative restore method (minor).
- No warning about `--delete` in rsync potentially destroying the target if source is accidentally empty.

### Scripts Quality

All three scripts (`backup-restic.sh`, `backup-postgres.sh`, `backup-verify.sh`) are production-grade:
- Proper `set -euo pipefail`
- Lock file management
- Slack/healthcheck notifications
- GFS retention policies
- JSON report generation (verify script)
- Metadata recording with checksums

### Assets Quality

- **s3-lifecycle-policy.json**: Valid JSON, correct AWS structure, includes compliance/standard tags, multipart cleanup.
- **restic-systemd/**: Security-hardened service unit (ProtectSystem, PrivateTmp, NoNewPrivileges, CPU/memory limits). Timer has Persistent=true and jitter.
- **backup-policy-template.md**: Thorough organizational template with compliance mapping (SOC 2, HIPAA, GDPR, PCI DSS).

### References Quality

All three reference docs are substantial (25-37 KB each) covering advanced patterns (deduplication, immutable storage, microservices), troubleshooting (corruption repair, performance analysis, lock contention), and DR planning (runbook templates, tabletop exercises, Terraform automation).

---

## c. Trigger Check

| Aspect | Assessment |
|--------|------------|
| Description specificity | Strong — names 15+ specific tools/concepts |
| Positive trigger coverage | Comprehensive: backup, DR, rsync, restic, borg, pg_dump, snapshot, automation, restore |
| Negative trigger clarity | Good: HA/failover, replication, and git are reasonable exclusions |
| False positive risk | Low-moderate: "rsync" alone could trigger for simple file-copy questions that aren't backup-related |
| False negative risk | Low: description covers nearly all backup-related keywords |
| Description length | Appropriate — detailed enough for confident matching without being overwhelming |

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | One factual bug (`pg_dump -Fc -j4` — `-j` is silently ignored with `-Fc`, only works with `-Fd`). All other commands, concepts, and configurations verified correct. |
| **Completeness** | 5 | Exceptionally thorough: covers filesystem/DB/cloud/snapshot/K8s backups, encryption, retention, automation, monitoring, bare-metal restore, verification. Three reference docs, three scripts, three asset groups. |
| **Actionability** | 5 | Every section has copy-paste commands. Production-ready scripts with lock management, notifications, and error handling. Systemd units are security-hardened. Policy template is fill-in-the-blank ready. |
| **Trigger quality** | 4 | Strong positive and negative triggers. Minor false-positive risk on "rsync" for non-backup use cases. |
| **Overall** | **4.5** | High-quality skill with one correctness bug to fix. |

---

## e. Issues

No GitHub issues required (overall 4.5 ≥ 4.0, no dimension ≤ 2).

### Recommended Fix (non-blocking)

**Line 117 of SKILL.md:** Change `pg_dump -Fc -j4` to `pg_dump -Fd -j4` with a directory output path, or remove `-j4` from the `-Fc` example and add a note that parallel dump requires directory format. The current command is misleading because `-j` is silently ignored with custom format.

---

## f. SKILL.md Tag

`<!-- tested: pass -->` appended to SKILL.md.
