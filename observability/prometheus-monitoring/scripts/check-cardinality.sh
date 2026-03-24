#!/usr/bin/env bash
# check-cardinality.sh — Analyze Prometheus TSDB cardinality using the status API.
# Reports top series by metric name, top label pairs, and storage estimates.
#
# Usage:
#   ./check-cardinality.sh [prometheus_url]
#
# Default URL: http://localhost:9090

set -euo pipefail

PROM_URL="${1:-http://localhost:9090}"
TOP_N="${TOP_N:-20}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

check_deps() {
  for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: '$cmd' is required but not installed." >&2
      exit 1
    fi
  done
}

query_prom() {
  local endpoint="$1"
  curl -sf --max-time 30 "${PROM_URL}${endpoint}" || {
    echo "ERROR: Failed to query ${PROM_URL}${endpoint}" >&2
    echo "Is Prometheus running at ${PROM_URL}?" >&2
    exit 1
  }
}

query_instant() {
  local expr="$1"
  curl -sf --max-time 30 "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=${expr}" | jq -r '.data.result[0].value[1] // "N/A"'
}

separator() {
  printf '\n%s\n' "$(printf '=%.0s' {1..70})"
}

# ─── Main ────────────────────────────────────────────────────────────────────

check_deps

echo "Prometheus Cardinality Report"
echo "Target: ${PROM_URL}"
echo "Date:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── TSDB Overview ────────────────────────────────────────────────────────────
separator
echo "TSDB OVERVIEW"
separator

HEAD_SERIES=$(query_instant "prometheus_tsdb_head_series")
HEAD_CHUNKS=$(query_instant "prometheus_tsdb_head_chunks")
WAL_SIZE=$(query_instant "prometheus_tsdb_wal_storage_size_bytes")
INGESTION_RATE=$(query_instant "rate(prometheus_tsdb_head_samples_appended_total[5m])")
CHURN_RATE=$(query_instant "rate(prometheus_tsdb_head_series_created_total[5m])")
MEMORY=$(query_instant "process_resident_memory_bytes")

printf "%-35s %s\n" "Active time series:" "${HEAD_SERIES}"
printf "%-35s %s\n" "Head chunks:" "${HEAD_CHUNKS}"
printf "%-35s %s\n" "WAL size (bytes):" "${WAL_SIZE}"
printf "%-35s %s\n" "Ingestion rate (samples/sec):" "${INGESTION_RATE}"
printf "%-35s %s\n" "Series churn rate (created/sec):" "${CHURN_RATE}"
printf "%-35s %s\n" "Process memory (bytes):" "${MEMORY}"

# Memory estimate
if [[ "${HEAD_SERIES}" != "N/A" && "${HEAD_SERIES}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  ESTIMATED_MEM_GB=$(echo "${HEAD_SERIES}" | awk '{printf "%.2f", ($1 * 3) / 1024 / 1024 / 1024}')
  printf "%-35s ~%s GB (at ~3KB/series)\n" "Estimated minimum memory:" "${ESTIMATED_MEM_GB}"
fi

# ── Top Metrics by Series Count ──────────────────────────────────────────────
separator
echo "TOP ${TOP_N} METRICS BY SERIES COUNT"
separator

TSDB_STATUS=$(query_prom "/api/v1/status/tsdb")

echo "${TSDB_STATUS}" | jq -r "
  .data.seriesCountByMetricName[:${TOP_N}] // [] |
  [\"METRIC\", \"SERIES_COUNT\"], [\"------\", \"------------\"],
  (.[] | [.name, (.value | tostring)]) |
  @tsv
" 2>/dev/null | column -t -s $'\t' || echo "(TSDB status API not available)"

# ── Top Labels by Value Count ────────────────────────────────────────────────
separator
echo "TOP ${TOP_N} LABELS BY UNIQUE VALUE COUNT"
separator

echo "${TSDB_STATUS}" | jq -r "
  .data.labelValueCountByLabelName[:${TOP_N}] // [] |
  [\"LABEL_NAME\", \"UNIQUE_VALUES\"], [\"----------\", \"-------------\"],
  (.[] | [.name, (.value | tostring)]) |
  @tsv
" 2>/dev/null | column -t -s $'\t' || echo "(TSDB status API not available)"

# ── Top Label Pairs by Series Count ──────────────────────────────────────────
separator
echo "TOP ${TOP_N} LABEL-VALUE PAIRS BY SERIES COUNT"
separator

echo "${TSDB_STATUS}" | jq -r "
  .data.seriesCountByLabelValuePair[:${TOP_N}] // [] |
  [\"LABEL=VALUE\", \"SERIES_COUNT\"], [\"-----------\", \"------------\"],
  (.[] | [.name, (.value | tostring)]) |
  @tsv
" 2>/dev/null | column -t -s $'\t' || echo "(TSDB status API not available)"

# ── Memory by Label Name ────────────────────────────────────────────────────
separator
echo "TOP ${TOP_N} LABELS BY MEMORY (BYTES)"
separator

echo "${TSDB_STATUS}" | jq -r "
  .data.memoryInBytesByLabelName[:${TOP_N}] // [] |
  [\"LABEL_NAME\", \"MEMORY_BYTES\"], [\"----------\", \"------------\"],
  (.[] | [.name, (.value | tostring)]) |
  @tsv
" 2>/dev/null | column -t -s $'\t' || echo "(TSDB status API not available)"

# ── Series per Job ───────────────────────────────────────────────────────────
separator
echo "SERIES COUNT PER JOB"
separator

JOBS_RESULT=$(curl -sf --max-time 30 "${PROM_URL}/api/v1/query" \
  --data-urlencode 'query=count by (job) ({__name__=~".+"})' 2>/dev/null || echo "")

if [[ -n "${JOBS_RESULT}" ]]; then
  echo "${JOBS_RESULT}" | jq -r '
    ["JOB", "SERIES_COUNT"], ["---", "------------"],
    (.data.result | sort_by(-.value[1] | tonumber) | .[] | [.metric.job, .value[1]]) |
    @tsv
  ' 2>/dev/null | column -t -s $'\t' || echo "(Query failed — may be too expensive)"
else
  echo "(Could not query series per job)"
fi

# ── Storage Growth Estimate ──────────────────────────────────────────────────
separator
echo "STORAGE GROWTH ESTIMATE"
separator

if [[ "${HEAD_SERIES}" != "N/A" && "${HEAD_SERIES}" =~ ^[0-9]+(\.[0-9]+)?$ && \
      "${INGESTION_RATE}" != "N/A" && "${INGESTION_RATE}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  # ~1-2 bytes per sample compressed
  BYTES_PER_SAMPLE=1.5
  DAILY_BYTES=$(echo "${INGESTION_RATE} ${BYTES_PER_SAMPLE}" | awk '{printf "%.0f", $1 * $2 * 86400}')
  DAILY_GB=$(echo "${DAILY_BYTES}" | awk '{printf "%.2f", $1 / 1024 / 1024 / 1024}')
  MONTHLY_GB=$(echo "${DAILY_GB}" | awk '{printf "%.2f", $1 * 30}')

  printf "%-35s %s samples/sec\n" "Current ingestion rate:" "${INGESTION_RATE}"
  printf "%-35s ~%s GB/day\n" "Estimated daily storage:" "${DAILY_GB}"
  printf "%-35s ~%s GB/month\n" "Estimated monthly storage:" "${MONTHLY_GB}"
  printf "%-35s ~%s GB\n" "15-day retention estimate:" "$(echo "${DAILY_GB}" | awk '{printf "%.2f", $1 * 15}')"
  printf "%-35s ~%s GB\n" "30-day retention estimate:" "${MONTHLY_GB}"
else
  echo "(Unable to estimate — metrics not available)"
fi

separator
echo "Done."
