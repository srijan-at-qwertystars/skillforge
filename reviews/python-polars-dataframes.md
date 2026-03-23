# QA Review: python/polars-dataframes

**Reviewer:** Copilot CLI  
**Date:** 2025-07-17  
**Skill path:** `python/polars-dataframes/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` and `description` | ✅ Pass | `name: polars-dataframes`, description present |
| Positive triggers in description | ✅ Pass | Lists imports (`polars`, `pl.DataFrame`, `pl.col`), actions (migrate from Pandas, optimize performance), keywords (`LazyFrame`, `scan_parquet`, `group_by`) |
| Negative triggers in description | ✅ Pass | Excludes Pandas-only, PySpark/Dask/Vaex, raw SQL, NumPy-only, R data.table/dplyr |
| Body under 500 lines | ✅ Pass | 479 lines (467 body lines after frontmatter) |
| Imperative voice, no filler | ✅ Pass | Direct, concise throughout. "Prefer lazy.", "Chain all transformations before `.collect()`" |
| Examples with input/output | ✅ Pass | `group_by` example has full input/output table; code examples throughout |
| `references/` linked from SKILL.md | ✅ Pass | Table at bottom lists all 3 reference files with descriptions |
| `scripts/` linked from SKILL.md | ✅ Pass | Table at bottom lists all 3 scripts with run commands |
| `assets/` linked from SKILL.md | ✅ Pass | Table at bottom lists all 3 assets with descriptions |

**Structure score: 9/9 — Excellent.**

---

## b. Content Check — API Accuracy (Polars 1.x)

### Issues Found

#### 1. `dtypes` parameter renamed to `schema_overrides` (MEDIUM)

Since Polars 0.20.31, `dtypes` in `read_csv`/`scan_csv` was renamed to `schema_overrides`. In Polars 1.x this emits a deprecation warning and will eventually break.

**Affected locations:**
- `SKILL.md` line 364: `dtypes={"id": pl.Int64}`
- `references/io-guide.md` line 37: `dtypes={"id": pl.Int64, "amount": pl.Float64}`
- `references/io-guide.md` line 57: `dtypes={"id": pl.Int64}`
- `scripts/csv-to-parquet.py` line 98: `csv_kwargs["dtypes"] = parse_dtypes(args.dtypes)`

**Fix:** Replace all `dtypes=` with `schema_overrides=` in read/scan calls.

#### 2. `streaming=True` in `collect()` deprecated (MEDIUM-HIGH)

Since Polars 1.23+, `lf.collect(streaming=True)` emits a deprecation warning. The modern API is `lf.collect(engine="streaming")`.

**Affected locations:**
- `SKILL.md` line 257: `result = lf.collect(streaming=True)`
- `SKILL.md` line 264: "Use `.collect(streaming=True)` for out-of-core processing"
- `references/advanced-patterns.md` lines 271, 109: `collect(streaming=True)`
- `references/advanced-patterns.md` line 234: `lf.collect(comm_subexpr_elim=True)` (also deprecated)
- `assets/cheatsheet.md` line 198: `result = lf.collect(streaming=True)`

**Fix:** Update to `lf.collect(engine="streaming")`. Mention both old and new API for version compatibility, or target Polars ≥1.23.

#### 3. `explain(format="tree")` not supported (LOW)

`lf.explain(format="tree")` does not work in stable Polars 1.x. Only text output is supported.

**Affected:** `references/advanced-patterns.md` line 255.

**Fix:** Remove or replace with `lf.explain()` (text is default).

#### 4. `read_database` used with URI argument (MEDIUM)

`SKILL.md` line 99: `pl.read_database("SELECT * FROM users", connection_uri)` is incorrect. `read_database` takes a `connection` object, not a URI string. For URI-based reads, use `pl.read_database_uri(query=..., uri=...)`.

**Fix:** Change to `pl.read_database_uri("SELECT * FROM users", connection_uri)`.

#### 5. `explain(streaming=True)` likely deprecated (LOW)

`references/advanced-patterns.md` line 297: `lf.explain(streaming=True)` — the `streaming` parameter in `explain()` follows the same deprecation path.

#### 6. Missing gotcha: `min_periods` → `min_samples` (LOW)

Rolling functions renamed `min_periods` to `min_samples` in Polars 1.21+. Not mentioned in migration guide or gotchas.

### Verified Correct

| API Area | Status |
|----------|--------|
| Expression API (`col`, `lit`, `when`/`then`/`otherwise`) | ✅ Correct |
| `over()` window functions | ✅ Correct |
| `group_by` (underscore form) | ✅ Correct |
| `with_columns`, `select`, `filter` contexts | ✅ Correct |
| Join types (`inner`, `left`, `right`, `full`, `cross`, `semi`, `anti`) | ✅ Correct |
| `sink_parquet` / `sink_csv` | ✅ Correct — not deprecated, actively maintained |
| `scan_csv`, `scan_parquet`, `scan_ndjson`, `scan_delta` | ✅ Correct |
| `read_database_uri` in `references/io-guide.md` | ✅ Correct |
| `pivot`/`unpivot` with `aggregate_function` | ✅ Correct |
| `rolling_mean`, `rolling_std` (integer-window) | ✅ Still valid |
| `rolling_mean_by` (time-based rolling) | ✅ Correctly named in advanced-patterns.md |
| Selectors module (`cs.numeric()`, etc.) | ✅ Correct |
| Struct/List operations | ✅ Correct |
| Pandas migration table | ✅ Accurate equivalents |
| Data types table | ✅ Correct (`String` canonical, `Utf8` legacy) |
| `Categorical` vs `Enum` | ✅ Correct |

---

## c. Trigger Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| Pushy enough? | ✅ Yes | Lists specific imports, method names, keywords. Covers both direct usage and migration scenarios |
| Would falsely trigger for Pandas-only? | ✅ No | Explicit exclusion: "Do NOT use for: Pandas-only code (import pandas)" |
| Distinguishes from PySpark/Dask? | ✅ Yes | Explicitly excludes "PySpark/Dask/Vaex distributed computing" |
| Covers migration queries? | ✅ Yes | "migrate from Pandas to Polars" included as trigger |
| Missing triggers? | ⚠️ Minor | Could add `pl.Enum`, `pl.SQLContext`, `polars.selectors` as trigger keywords |

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | Multiple deprecated API usages (`dtypes`, `streaming=True`, `explain(format="tree")`), wrong function in `read_database` example. These will produce warnings or errors on Polars ≥1.23. |
| **Completeness** | 4 | Excellent coverage of core API, expressions, IO, migration, and advanced patterns. Missing recent API changes (streaming engine transition, schema_overrides, min_samples). |
| **Actionability** | 5 | Outstanding. Runnable scripts (benchmark, profiler, CSV converter), production ETL template, Jupyter starter, comprehensive cheatsheet. Input/output examples where it matters. |
| **Trigger quality** | 4 | Strong positive and negative triggers. Could add a few more specific keywords but handles the major cases well. |
| **Overall** | **4.0** | Strong skill with excellent structure and actionability, but API accuracy needs updating for Polars 1.23+. |

---

## e. GitHub Issues

Overall = 4.0 (not < 4.0) and no dimension ≤ 2. **No issues filed.**

---

## f. Test Marker

`<!-- tested: needs-fix -->` appended to SKILL.md.

**Reason:** 4 API accuracy issues need correction before the skill reliably serves Polars 1.x users:
1. `dtypes` → `schema_overrides` (4 locations)
2. `streaming=True` → `engine="streaming"` (5+ locations)
3. `explain(format="tree")` removal (1 location)
4. `read_database` → `read_database_uri` (1 location)

---

## Summary of Required Fixes

| Priority | Fix | Files Affected |
|----------|-----|----------------|
| High | Replace `dtypes=` with `schema_overrides=` | SKILL.md, io-guide.md, csv-to-parquet.py |
| High | Replace `collect(streaming=True)` with `collect(engine="streaming")` | SKILL.md, advanced-patterns.md, cheatsheet.md |
| Medium | Fix `read_database` to `read_database_uri` | SKILL.md |
| Low | Remove `explain(format="tree")` | advanced-patterns.md |
| Low | Remove `collect(comm_subexpr_elim=True)` or verify | advanced-patterns.md |
| Low | Add `min_periods` → `min_samples` to gotchas | pandas-migration.md |
