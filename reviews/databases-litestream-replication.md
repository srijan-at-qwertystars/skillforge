# QA Review: databases/litestream-replication

**Reviewer:** Copilot CLI  
**Date:** 2025-07-17  
**Skill path:** `~/skillforge/databases/litestream-replication/`  
**Verdict:** ⚠️ needs-fix

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter | ✅ | name, description, positive/negative triggers all present |
| Line count | ✅ | 477 lines (under 500 limit) |
| Imperative voice | ✅ | Consistent throughout ("Set WAL mode…", "Enable with…", "Use `-exec`…") |
| Examples | ✅ | Rich: minimal/full config, Docker, K8s StatefulSet, CLI, health checks |
| References linked | ✅ | 3 reference docs linked in table with topic summaries |
| Scripts linked | ✅ | 3 scripts linked with purpose and usage examples |
| Assets linked | ✅ | 5 assets linked with descriptions |

**Structure: PASS** — well-organized with clear sections, tables, and cross-references.

---

## B. Content Check

### Verified Accurate
- ✅ `litestream replicate` / `litestream restore` syntax and flags correct
- ✅ `-if-db-not-exists`, `-if-replica-exists`, `-exec`, `-timestamp` flags verified
- ✅ `litestream snapshots`, `litestream generations`, `litestream databases` commands exist
- ✅ Config YAML structure (`dbs`, `replicas`, `sync-interval`, `snapshot-interval`, `retention`) correct
- ✅ Replica types (S3, GCS, ABS, SFTP, file) and URL forms accurate
- ✅ Environment variable `${VAR}` expansion syntax correct
- ✅ WAL mode prerequisite and VACUUM warning accurate
- ✅ Shadow WAL / generations / snapshot architecture description accurate
- ✅ Docker `-exec` flag for signal forwarding correctly documented
- ✅ K8s pattern with `replicas: 1` constraint correctly emphasized
- ✅ Alternatives table (LiteFS, rqlite, dqlite, cr-sqlite) accurate

### Issues Found

**1. `litestream validate` command does not exist (INACCURATE)**  
Line 208: `litestream validate s3://my-bucket/app` — this command was briefly available in v0.2.0 but was removed. It does not exist in v0.3.x or v0.5.x. The current CLI commands are: `databases`, `replicate`, `restore`, `snapshots`, `generations`, `version`, `wal` (deprecated), `ltx`, `sync`.  
**Severity: High** — users will get a "unknown command" error.

**2. No mention of v0.5.x breaking changes (OUTDATED)**  
The skill and assets pin to v0.3.13. Litestream v0.5.x (current: v0.5.9) introduced a new LTX backup format that is **not backward-compatible** with v0.3.x backups. The config format also changed (`replicas` → `replica`). The skill should either: (a) explicitly note it targets v0.3.x and warn about the migration, or (b) cover both versions.  
**Severity: Medium** — could cause confusion or failed restores during upgrades.

**3. `validation-interval` config key unverified**  
Lines 84, 387, 404: The `validation-interval` config option is referenced multiple times but does not appear in official Litestream documentation. This may be a fabricated configuration key.  
**Severity: Medium** — silent config ignore or startup error.

**4. CVE-2024-41254 not mentioned (MISSING GOTCHA)**  
v0.3.13 has a known CVE for insecure SSH configuration allowing MITM attacks when using SFTP replicas. This should be noted in the SFTP section or Limitations.  
**Severity: Low-Medium** — security-relevant for SFTP users.

**5. Silent replication failure gotcha missing (MISSING GOTCHA)**  
Known issue where replication can silently break if WAL size doesn't change under certain concurrency conditions. Should be in Limitations or troubleshooting.  
**Severity: Low** — edge case, but important for production awareness.

---

## C. Trigger Check

| Aspect | Assessment |
|---|---|
| Positive triggers specific to Litestream? | ✅ Yes — "Litestream", "litestream.yml", "SQLite replication", "WAL replication" are highly specific |
| Would general SQLite queries trigger? | ✅ No — negative trigger "general SQLite without replication" blocks this |
| Would PostgreSQL/MySQL replication trigger? | ✅ No — explicit negative triggers for both |
| Would LiteFS/rqlite trigger? | ✅ No — both listed as negative triggers |
| False positive risk | Low — "SQLite disaster recovery" could theoretically match non-Litestream DR, but combined with other signals this is acceptable |

**Triggers: PASS** — well-separated from adjacent domains.

---

## D. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 3/5 | Phantom `validate` command, unverified `validation-interval` config key, no v0.5.x coverage |
| **Completeness** | 4/5 | Excellent breadth (config, Docker, K8s, monitoring, alternatives). Missing: version migration notes, CVE, silent failure gotcha |
| **Actionability** | 5/5 | Production checklist, copy-paste configs, operational scripts, troubleshooting reference. A user could go from zero to deployed |
| **Trigger Quality** | 5/5 | Precise positive triggers, thorough negative exclusions, low false-positive risk |
| **Overall** | **4.25/5** | Strong skill with targeted accuracy fixes needed |

---

## E. Required Fixes

1. **Remove or correct `litestream validate` command** on line 208. Replace with a manual validation approach (restore to temp + integrity_check), or note it was removed.
2. **Add version scope note** — state the skill targets v0.3.x and add a warning about v0.5.x breaking changes (LTX format, config schema changes, backup incompatibility).
3. **Verify or remove `validation-interval`** — confirm this config key exists in v0.3.13 or remove references.
4. **Add CVE-2024-41254 note** to SFTP section or Limitations.

## F. Recommended Improvements (non-blocking)

- Add a "Version Compatibility" section covering v0.3.x vs v0.5.x differences
- Mention silent replication failure edge case in Limitations
- Note that `litestream.yml` must use `.yml` extension (not `.yaml`) per official docs
- docker-compose.yml asset references `./litestream-dev.yml` which is not provided in assets

---

## G. Issue Filing

No GitHub issues filed — overall score (4.25) ≥ 4.0 and no dimension ≤ 2.
