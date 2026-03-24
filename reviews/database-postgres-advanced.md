# Review: postgres-advanced

Accuracy: 5/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **PgBouncer restrictions incomplete in SKILL.md (minor):** Line 273 lists transaction-mode restrictions as "prepared statements, session vars, advisory locks, temp tables" but omits LISTEN/NOTIFY and LOAD. The pgbouncer.ini asset has the complete list, but SKILL.md should be self-sufficient for quick reference.

2. **`nobarrier` mount option deprecated (reference file):** `references/performance-tuning.md` line 517 recommends `nobarrier` for ext4. This option was removed in Linux kernel 4.13+ (barriers always enabled). Could mislead users on modern systems.

3. **Fragile partition cleanup function (asset file):** `assets/partitioning-template.sql` `drop_old_partitions()` uses a regex matching the year string in the partition name (line 106), which is unreliable for multi-year retention or non-standard naming.

4. **BRIN "1000x smaller" claim slightly imprecise:** SKILL.md line 62 states BRIN is "1000x smaller than B-tree." Real-world range is 100x–1000x depending on data correlation and `pages_per_range`. The claim is at the upper bound; "up to 1000x" would be more accurate.

## Structure Assessment

- ✅ YAML frontmatter: `name` and `description` present
- ✅ Description: positive triggers (optimization, indexing, partitioning, etc.) AND negative triggers (not basic CRUD, not install, not other DBs)
- ✅ Body: 498 lines (under 500 limit)
- ✅ Imperative voice throughout, zero filler
- ✅ Extensive examples with input/output annotations
- ✅ All references/, scripts/, and assets/ properly linked from SKILL.md

## Verification Summary

| Claim | Verified |
|-------|----------|
| PG12+ inlines non-recursive CTEs | ✅ Correct |
| CYCLE clause PG14+ | ✅ Correct |
| PgBouncer 1.21+ prepared statement forwarding | ✅ Correct |
| VACUUM PARALLEL PG13+ | ✅ Correct |
| wal_compression lz4/zstd PG15+ | ✅ Correct |
| gen_random_uuid() PG13+ | ✅ Correct |
| BRIN up to 1000x smaller | ✅ Upper bound of documented range |

## Verdict

**PASS** — High-quality skill with accurate technical content, comprehensive coverage, and excellent actionability. Minor issues are in supporting files and do not impede AI execution. No GitHub issue required.
