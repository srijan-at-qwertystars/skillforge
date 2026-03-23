# Review: duckdb-analytics

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:

1. **Excel reading uses deprecated approach (SKILL.md L148-149):** Shows `INSTALL spatial; LOAD spatial;` + `st_read('data.xlsx')` for Excel files. As of DuckDB 1.2.0+, the dedicated `excel` extension with `read_xlsx()` is recommended and `spatial` for Excel is deprecated. The extensions table (L383) correctly lists the `excel` extension, but the "Reading External Data" example contradicts it.

2. **`experimental_parallel_csv` setting is obsolete (SKILL.md L272):** `SET experimental_parallel_csv = true;` is deprecated/removed. Parallel CSV loading is now controlled via the `parallel` parameter in `read_csv()` / `read_csv_auto()` function calls, e.g. `read_csv('file.csv', parallel=true)`.

3. **Questionable ETL template expression (assets/etl-pipeline.py L147):** `md5(CAST(COLUMNS(*) AS VARCHAR))` — `COLUMNS(*)` expands to multiple columns and `md5()` takes a single string argument. This would likely error at runtime. Consider `md5(CAST(row_to_json(deduped.*) AS VARCHAR))` or hashing a concatenation.

Strengths:

- Version info (v1.4.0 LTS "Andium") is current and accurate.
- MERGE INTO (v1.4+), USING KEY (v1.3+) version annotations are correct.
- Trigger description is excellent: positive triggers cover key use cases (Parquet, embedded OLAP, columnar, data lake, extensions), negative triggers correctly exclude OLTP, distributed, and NoSQL workloads.
- 499 lines — just under the 500-line body limit.
- Imperative voice throughout, no filler.
- All references/, scripts/, and assets/ are properly linked from the Resources section.
- Anti-patterns and gotchas section is thorough and practical.
- Shell scripts (explore, benchmark, parquet-inspect) are well-structured with proper error handling.
- Python cookbook covers Flask, FastAPI, pytest, UDFs, streaming — comprehensive real-world coverage.
- Comparison table (DuckDB vs SQLite/Pandas/Polars/Spark/ClickHouse) is accurate and helpful.

Trigger check:
- ✅ "analyze Parquet files with SQL" → triggers (matches Parquet, analytical SQL, data analysis keywords)
- ✅ "PostgreSQL query optimization" → does NOT trigger (negative trigger excludes OLTP/PostgreSQL)
