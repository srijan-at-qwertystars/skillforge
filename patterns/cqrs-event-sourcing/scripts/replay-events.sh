#!/usr/bin/env bash
# ==============================================================================
# replay-events.sh — Template for replaying events to rebuild read model projections
#
# Usage:
#   ./replay-events.sh                           # Replay all events, rebuild all projections
#   ./replay-events.sh --projection order_summary # Rebuild a single projection
#   ./replay-events.sh --from-position 50000      # Replay from a specific global position
#   ./replay-events.sh --batch-size 500           # Custom batch size
#   ./replay-events.sh --dry-run                  # Show what would be replayed without applying
#
# Environment variables:
#   DATABASE_URL   PostgreSQL connection string (default: postgresql://localhost:5432/eventstore)
#   BATCH_SIZE     Events per batch (default: 1000)
#
# Adapt: Replace the projection rebuild logic in rebuild_projection() with your actual code.
# ==============================================================================
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://localhost:5432/eventstore}"
BATCH_SIZE="${BATCH_SIZE:-1000}"
PROJECTION=""
FROM_POSITION=0
DRY_RUN=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --projection)    PROJECTION="$2"; shift 2 ;;
    --from-position) FROM_POSITION="$2"; shift 2 ;;
    --batch-size)    BATCH_SIZE="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)
      head -17 "$0" | tail -15
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Helpers ---
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

run_sql() {
  psql "${DATABASE_URL}" -t -A -c "$1" 2>/dev/null
}

check_psql() {
  if ! command -v psql &>/dev/null; then
    echo "ERROR: psql is not installed. Install PostgreSQL client tools." >&2
    exit 1
  fi
}

# --- Get event store stats ---
get_total_events() {
  run_sql "SELECT COUNT(*) FROM events WHERE global_position >= ${FROM_POSITION};"
}

get_max_position() {
  run_sql "SELECT COALESCE(MAX(global_position), 0) FROM events;"
}

# --- Reset projection checkpoint ---
reset_checkpoint() {
  local proj_name="$1"
  log "Resetting checkpoint for projection: ${proj_name}"
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would reset ${proj_name} checkpoint to ${FROM_POSITION}"
    return
  fi
  run_sql "
    INSERT INTO projection_checkpoints (projection_name, last_processed_position, updated_at)
    VALUES ('${proj_name}', ${FROM_POSITION}, now())
    ON CONFLICT (projection_name)
    DO UPDATE SET last_processed_position = ${FROM_POSITION}, updated_at = now();
  "
}

# --- Clear projection read model ---
clear_read_model() {
  local proj_name="$1"
  log "Clearing read model for: ${proj_name}"
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would truncate read model table for ${proj_name}"
    return
  fi

  # =====================================================================
  # CUSTOMIZE: Map projection names to their read model tables
  # =====================================================================
  case "${proj_name}" in
    order_summary)
      run_sql "TRUNCATE TABLE order_summary_read_model;"
      ;;
    customer_orders)
      run_sql "TRUNCATE TABLE customer_orders_read_model;"
      ;;
    *)
      log "WARNING: No read model table mapping for '${proj_name}'. Add it to clear_read_model()."
      ;;
  esac
}

# --- Replay events in batches ---
replay_batch() {
  local start_pos="$1"
  local batch_size="$2"
  local proj_filter="$3"

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would process events from position ${start_pos}, batch size ${batch_size}"
    return 0
  fi

  # =====================================================================
  # CUSTOMIZE: Replace this with your actual projection handler invocation.
  #
  # Options:
  #   1. Call your application's replay endpoint:
  #      curl -X POST "http://localhost:3000/admin/replay" \
  #        -H "Content-Type: application/json" \
  #        -d "{\"fromPosition\": ${start_pos}, \"batchSize\": ${batch_size}, \"projection\": \"${proj_filter}\"}"
  #
  #   2. Run a Node.js/Python script:
  #      node ./scripts/replay-worker.js --from ${start_pos} --batch ${batch_size}
  #
  #   3. Direct SQL-based projection (for simple cases):
  #      See the inline example below.
  # =====================================================================

  # Example: Direct SQL projection rebuild for order_summary
  run_sql "
    WITH batch AS (
      SELECT global_position, stream_id, event_type, data, metadata
      FROM events
      WHERE global_position >= ${start_pos}
      ORDER BY global_position
      LIMIT ${batch_size}
    )
    SELECT COUNT(*) FROM batch;
  "
}

# --- Main replay logic ---
main() {
  check_psql
  log "=== Event Replay Started ==="
  log "Database:       ${DATABASE_URL}"
  log "Batch size:     ${BATCH_SIZE}"
  log "From position:  ${FROM_POSITION}"
  log "Projection:     ${PROJECTION:-ALL}"
  log "Dry run:        ${DRY_RUN}"

  local total
  total=$(get_total_events)
  local max_pos
  max_pos=$(get_max_position)
  log "Total events to replay: ${total}"
  log "Max global position:    ${max_pos}"

  if [ "$total" -eq 0 ]; then
    log "No events to replay."
    exit 0
  fi

  # Reset checkpoints
  if [ -n "$PROJECTION" ]; then
    reset_checkpoint "$PROJECTION"
    clear_read_model "$PROJECTION"
  else
    log "Resetting all projection checkpoints..."
    for proj in $(run_sql "SELECT projection_name FROM projection_checkpoints;"); do
      reset_checkpoint "$proj"
      clear_read_model "$proj"
    done
  fi

  # Replay in batches
  local current_pos=${FROM_POSITION}
  local processed=0
  local start_time
  start_time=$(date +%s)

  while [ "$current_pos" -le "$max_pos" ]; do
    local batch_count
    batch_count=$(replay_batch "$current_pos" "$BATCH_SIZE" "$PROJECTION")
    processed=$((processed + BATCH_SIZE))
    current_pos=$((current_pos + BATCH_SIZE))

    # Progress
    local elapsed=$(( $(date +%s) - start_time ))
    local rate=0
    [ "$elapsed" -gt 0 ] && rate=$((processed / elapsed))
    log "Progress: position ${current_pos} / ${max_pos} | ${processed} events | ${rate} events/sec"
  done

  log "=== Replay Complete ==="
  log "Total processed: ~${processed} events in $(($(date +%s) - start_time))s"
}

main
