#!/usr/bin/env bash
# =============================================================================
# analyze-cache.sh — Analyze Turborepo cache hit rates and identify issues
# =============================================================================
# Usage:
#   ./analyze-cache.sh [options]
#
# Options:
#   --tasks <task1,task2,...>  Tasks to analyze (default: build,test,lint)
#   --json                    Output raw JSON instead of formatted report
#   --verbose                 Show per-package breakdown
#
# Examples:
#   ./analyze-cache.sh                              # Analyze build,test,lint
#   ./analyze-cache.sh --tasks build                # Analyze build only
#   ./analyze-cache.sh --verbose                    # Per-package details
#   ./analyze-cache.sh --json                       # Machine-readable output
#
# Requirements:
#   - Must be run from the monorepo root (where turbo.json lives)
#   - Requires jq for JSON processing
#   - Runs turbo with --dry=json (no actual execution)
# =============================================================================
set -euo pipefail

# --- Defaults ---
TASKS="build,test,lint"
OUTPUT_JSON=false
VERBOSE=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --tasks)
      TASKS="$2"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      head -20 "$0" | grep "^#" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Validate ---
if [[ ! -f "turbo.json" ]]; then
  echo "Error: turbo.json not found. Run this script from the monorepo root."
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required. Install with: brew install jq / apt install jq"
  exit 1
fi

# Convert comma-separated tasks to space-separated
TASK_LIST="${TASKS//,/ }"

echo "🔍 Analyzing Turborepo cache for tasks: ${TASK_LIST}"
echo ""

# --- Run turbo summarize ---
# Use --summarize to get actual cache status (requires running the tasks)
# If you want dry-run only, use --dry=json (but it won't show cache status)

SUMMARY_FILE=$(mktemp)
trap 'rm -f "$SUMMARY_FILE"' EXIT

# Run with summarize to get real cache data
if turbo run ${TASK_LIST} --summarize 2>/dev/null; then
  # Find the latest summary file
  LATEST_SUMMARY=$(find .turbo/runs -name "*.json" -type f 2>/dev/null | sort | tail -1)

  if [[ -z "$LATEST_SUMMARY" || ! -f "$LATEST_SUMMARY" ]]; then
    echo "⚠ No summary file found. Falling back to dry run analysis."
    turbo run ${TASK_LIST} --dry=json 2>/dev/null > "$SUMMARY_FILE"
    USE_DRY=true
  else
    cp "$LATEST_SUMMARY" "$SUMMARY_FILE"
    USE_DRY=false
  fi
else
  echo "⚠ turbo run failed. Falling back to dry run analysis."
  turbo run ${TASK_LIST} --dry=json 2>/dev/null > "$SUMMARY_FILE" || true
  USE_DRY=true
fi

# --- Analyze results ---
if [[ "$OUTPUT_JSON" == true ]]; then
  cat "$SUMMARY_FILE"
  exit 0
fi

echo "═══════════════════════════════════════════════════════════"
echo "                   CACHE ANALYSIS REPORT"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [[ "$USE_DRY" == true ]]; then
  # Dry run analysis (limited info)
  TOTAL_TASKS=$(jq '.tasks | length' "$SUMMARY_FILE" 2>/dev/null || echo "0")
  PACKAGES=$(jq -r '[.tasks[].package] | unique | .[]' "$SUMMARY_FILE" 2>/dev/null || echo "none")

  echo "📊 Task Graph Summary (dry run — no cache status available)"
  echo "   Total tasks:   ${TOTAL_TASKS}"
  echo "   Packages:      $(echo "$PACKAGES" | wc -l | xargs)"
  echo ""

  if [[ "$VERBOSE" == true ]]; then
    echo "📦 Tasks per package:"
    jq -r '.tasks[] | "   \(.package)#\(.task)"' "$SUMMARY_FILE" 2>/dev/null || true
    echo ""
  fi

  echo "💡 For actual cache hit/miss data, run without --dry:"
  echo "   turbo run ${TASK_LIST} --summarize"
else
  # Full summary analysis
  TOTAL_TASKS=$(jq '.tasks | length' "$SUMMARY_FILE" 2>/dev/null || echo "0")

  if [[ "$TOTAL_TASKS" == "0" ]]; then
    echo "No tasks found in summary."
    exit 0
  fi

  CACHE_HITS=$(jq '[.tasks[] | select(.cache.status == "HIT")] | length' "$SUMMARY_FILE" 2>/dev/null || echo "0")
  CACHE_MISSES=$(jq '[.tasks[] | select(.cache.status == "MISS")] | length' "$SUMMARY_FILE" 2>/dev/null || echo "0")

  if [[ "$TOTAL_TASKS" -gt 0 ]]; then
    HIT_RATE=$(( CACHE_HITS * 100 / TOTAL_TASKS ))
  else
    HIT_RATE=0
  fi

  echo "📊 Overall Cache Statistics"
  echo "   Total tasks:    ${TOTAL_TASKS}"
  echo "   Cache hits:     ${CACHE_HITS} ✅"
  echo "   Cache misses:   ${CACHE_MISSES} ❌"
  echo "   Hit rate:       ${HIT_RATE}%"
  echo ""

  # Cache status by task type
  echo "📋 Cache Status by Task Type:"
  for task in ${TASK_LIST}; do
    TASK_TOTAL=$(jq "[.tasks[] | select(.task == \"${task}\")] | length" "$SUMMARY_FILE" 2>/dev/null || echo "0")
    TASK_HITS=$(jq "[.tasks[] | select(.task == \"${task}\" and .cache.status == \"HIT\")] | length" "$SUMMARY_FILE" 2>/dev/null || echo "0")
    if [[ "$TASK_TOTAL" -gt 0 ]]; then
      TASK_RATE=$(( TASK_HITS * 100 / TASK_TOTAL ))
      echo "   ${task}: ${TASK_HITS}/${TASK_TOTAL} hits (${TASK_RATE}%)"
    fi
  done
  echo ""

  if [[ "$VERBOSE" == true ]]; then
    echo "📦 Per-Package Breakdown:"
    echo ""
    jq -r '.tasks[] | "   \(.cache.status // "N/A") \(.package)#\(.task) [\(.hash // "unknown" | .[0:12])]"' "$SUMMARY_FILE" 2>/dev/null | sort || true
    echo ""
  fi

  # Identify tasks with poor caching
  if [[ "$CACHE_MISSES" -gt 0 ]]; then
    echo "⚠ Tasks with Cache Misses:"
    jq -r '.tasks[] | select(.cache.status == "MISS") | "   ❌ \(.package)#\(.task)"' "$SUMMARY_FILE" 2>/dev/null || true
    echo ""
    echo "💡 Tips for improving cache hit rate:"
    echo "   - Ensure env vars are listed in turbo.json 'env' field"
    echo "   - Use 'inputs' to narrow which files affect the cache hash"
    echo "   - Check for non-deterministic outputs (timestamps, random values)"
    echo "   - Verify .gitignore excludes generated/volatile files"
    echo "   - Run: turbo run build --summarize --verbosity=2 for details"
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"

# --- Additional diagnostics ---
echo ""
echo "🔧 Diagnostics:"

# Check turbo daemon
if turbo daemon status &>/dev/null; then
  echo "   ✅ Turbo daemon is running"
else
  echo "   ⚠ Turbo daemon is not running (start with: turbo daemon start)"
fi

# Check remote cache config
if [[ -n "${TURBO_TOKEN:-}" && -n "${TURBO_TEAM:-}" ]]; then
  echo "   ✅ Remote cache configured (TURBO_TOKEN + TURBO_TEAM set)"
elif [[ -f ".turbo/config.json" ]]; then
  echo "   ✅ Remote cache configured via .turbo/config.json"
else
  echo "   ⚠ Remote cache not configured (run: turbo login && turbo link)"
fi

# Check local cache size
if [[ -d "node_modules/.cache/turbo" ]]; then
  CACHE_SIZE=$(du -sh "node_modules/.cache/turbo" 2>/dev/null | cut -f1)
  echo "   📁 Local cache size: ${CACHE_SIZE}"
elif [[ -d ".turbo" ]]; then
  CACHE_SIZE=$(du -sh ".turbo" 2>/dev/null | cut -f1)
  echo "   📁 .turbo directory size: ${CACHE_SIZE}"
fi

echo ""
