#!/usr/bin/env bash
# =============================================================================
# index-management.sh — Elasticsearch index lifecycle operations
#
# Usage:
#   ./index-management.sh <action> <index_name> [OPTIONS]
#
# Actions:
#   create    <index> [--mapping FILE] [--shards N] [--replicas N]
#   delete    <index> [--force]
#   reindex   <source> --dest <dest> [--pipeline NAME] [--slices N]
#   alias     <alias> --add <index> [--remove <old_index>]
#   swap      <alias> --from <old_index> --to <new_index>
#   info      <index>
#   list      [--pattern PATTERN]
#   close     <index>
#   open      <index>
#   refresh   <index>
#   forcemerge <index> [--segments N]
#
# Options:
#   --url URL         Elasticsearch URL (default: http://localhost:9200)
#   -u USER:PASS      Basic auth
#   -k KEY            API key
#   --insecure        Skip TLS verification
#
# Examples:
#   ./index-management.sh create products --mapping mappings.json --shards 3
#   ./index-management.sh reindex products-v1 --dest products-v2
#   ./index-management.sh swap products --from products-v1 --to products-v2
#   ./index-management.sh delete old-index --force
#   ./index-management.sh list --pattern "logs-*"
# =============================================================================

set -euo pipefail

ES_URL="http://localhost:9200"
AUTH_ARGS=()
CURL_OPTS=(-s -S --connect-timeout 5 --max-time 300)

# Parse global options first, collect positional args
POSITIONAL=()
MAPPING_FILE=""
SHARDS=1
REPLICAS=1
DEST=""
PIPELINE=""
SLICES="auto"
ADD_INDEX=""
REMOVE_INDEX=""
FROM_INDEX=""
TO_INDEX=""
PATTERN="*"
FORCE=false
SEGMENTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) ES_URL="${2%/}"; shift 2 ;;
    -u) AUTH_ARGS+=("-u" "$2"); shift 2 ;;
    -k) AUTH_ARGS+=("-H" "Authorization: ApiKey $2"); shift 2 ;;
    --insecure) AUTH_ARGS+=("-k"); shift ;;
    --mapping) MAPPING_FILE="$2"; shift 2 ;;
    --shards) SHARDS="$2"; shift 2 ;;
    --replicas) REPLICAS="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --pipeline) PIPELINE="$2"; shift 2 ;;
    --slices) SLICES="$2"; shift 2 ;;
    --add) ADD_INDEX="$2"; shift 2 ;;
    --remove) REMOVE_INDEX="$2"; shift 2 ;;
    --from) FROM_INDEX="$2"; shift 2 ;;
    --to) TO_INDEX="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --segments) SEGMENTS="$2"; shift 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

ACTION="${POSITIONAL[0]:-}"
INDEX="${POSITIONAL[1]:-}"

es_request() {
  local method="$1" path="$2"
  shift 2
  curl "${CURL_OPTS[@]}" "${AUTH_ARGS[@]}" -X "$method" \
    -H "Content-Type: application/json" \
    "${ES_URL}${path}" "$@" 2>/dev/null
}

die() { echo "❌ $1" >&2; exit 1; }
ok()  { echo "✅ $1"; }
info() { echo "ℹ️  $1"; }

case "$ACTION" in
  create)
    [[ -z "$INDEX" ]] && die "Usage: $0 create <index_name> [--mapping FILE] [--shards N] [--replicas N]"

    BODY="{\"settings\":{\"number_of_shards\":${SHARDS},\"number_of_replicas\":${REPLICAS}}"
    if [[ -n "$MAPPING_FILE" ]]; then
      [[ ! -f "$MAPPING_FILE" ]] && die "Mapping file not found: $MAPPING_FILE"
      MAPPINGS=$(cat "$MAPPING_FILE")
      BODY="${BODY},\"mappings\":${MAPPINGS}}"
    else
      BODY="${BODY}}"
    fi

    info "Creating index '${INDEX}' (shards=${SHARDS}, replicas=${REPLICAS})..."
    RESULT=$(es_request PUT "/${INDEX}" -d "$BODY")

    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Index '${INDEX}' created successfully"
    else
      die "Failed to create index: $RESULT"
    fi
    ;;

  delete)
    [[ -z "$INDEX" ]] && die "Usage: $0 delete <index_name> [--force]"

    if [[ "$FORCE" != true ]]; then
      echo "⚠️  This will permanently delete index '${INDEX}' and all its data."
      read -rp "Type the index name to confirm: " CONFIRM
      [[ "$CONFIRM" != "$INDEX" ]] && die "Confirmation failed. Aborting."
    fi

    info "Deleting index '${INDEX}'..."
    RESULT=$(es_request DELETE "/${INDEX}")

    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Index '${INDEX}' deleted"
    else
      die "Failed to delete index: $RESULT"
    fi
    ;;

  reindex)
    [[ -z "$INDEX" || -z "$DEST" ]] && die "Usage: $0 reindex <source_index> --dest <dest_index> [--pipeline NAME]"

    BODY="{\"source\":{\"index\":\"${INDEX}\"},\"dest\":{\"index\":\"${DEST}\""
    [[ -n "$PIPELINE" ]] && BODY="${BODY},\"pipeline\":\"${PIPELINE}\""
    BODY="${BODY}}}"

    info "Reindexing '${INDEX}' → '${DEST}' (slices=${SLICES})..."
    RESULT=$(es_request POST "/_reindex?wait_for_completion=false&slices=${SLICES}" -d "$BODY")

    TASK_ID=$(echo "$RESULT" | grep -o '"task" *: *"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$TASK_ID" ]]; then
      ok "Reindex started. Task ID: ${TASK_ID}"
      echo "   Monitor: curl ${ES_URL}/_tasks/${TASK_ID}"
    else
      die "Failed to start reindex: $RESULT"
    fi
    ;;

  alias)
    [[ -z "$INDEX" ]] && die "Usage: $0 alias <alias_name> --add <index> [--remove <old_index>]"
    [[ -z "$ADD_INDEX" ]] && die "--add <index> is required"

    ACTIONS="[{\"add\":{\"index\":\"${ADD_INDEX}\",\"alias\":\"${INDEX}\"}}"
    [[ -n "$REMOVE_INDEX" ]] && ACTIONS="${ACTIONS},{\"remove\":{\"index\":\"${REMOVE_INDEX}\",\"alias\":\"${INDEX}\"}}"
    ACTIONS="${ACTIONS}]"

    info "Updating alias '${INDEX}'..."
    RESULT=$(es_request POST "/_aliases" -d "{\"actions\":${ACTIONS}}")

    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Alias '${INDEX}' updated"
      [[ -n "$ADD_INDEX" ]] && echo "   Added: ${ADD_INDEX}"
      [[ -n "$REMOVE_INDEX" ]] && echo "   Removed: ${REMOVE_INDEX}"
    else
      die "Failed to update alias: $RESULT"
    fi
    ;;

  swap)
    [[ -z "$INDEX" || -z "$FROM_INDEX" || -z "$TO_INDEX" ]] && \
      die "Usage: $0 swap <alias> --from <old_index> --to <new_index>"

    info "Atomically swapping alias '${INDEX}': ${FROM_INDEX} → ${TO_INDEX}..."
    BODY="{\"actions\":[{\"remove\":{\"index\":\"${FROM_INDEX}\",\"alias\":\"${INDEX}\"}},{\"add\":{\"index\":\"${TO_INDEX}\",\"alias\":\"${INDEX}\"}}]}"
    RESULT=$(es_request POST "/_aliases" -d "$BODY")

    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Alias '${INDEX}' now points to '${TO_INDEX}'"
    else
      die "Failed to swap alias: $RESULT"
    fi
    ;;

  info)
    [[ -z "$INDEX" ]] && die "Usage: $0 info <index_name>"
    echo "=== Index: ${INDEX} ==="
    echo ""
    echo "--- Settings ---"
    es_request GET "/${INDEX}/_settings?flat_settings=true" | python3 -m json.tool 2>/dev/null || \
      es_request GET "/${INDEX}/_settings?flat_settings=true"
    echo ""
    echo "--- Mappings ---"
    es_request GET "/${INDEX}/_mapping" | python3 -m json.tool 2>/dev/null || \
      es_request GET "/${INDEX}/_mapping"
    echo ""
    echo "--- Stats ---"
    es_request GET "/${INDEX}/_stats/store,docs,indexing,search" | python3 -m json.tool 2>/dev/null || \
      es_request GET "/${INDEX}/_stats/store,docs,indexing,search"
    ;;

  list)
    es_request GET "/_cat/indices/${PATTERN}?v&s=index&h=index,health,status,pri,rep,docs.count,store.size"
    ;;

  close)
    [[ -z "$INDEX" ]] && die "Usage: $0 close <index_name>"
    info "Closing index '${INDEX}'..."
    RESULT=$(es_request POST "/${INDEX}/_close")
    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Index '${INDEX}' closed"
    else
      die "Failed: $RESULT"
    fi
    ;;

  open)
    [[ -z "$INDEX" ]] && die "Usage: $0 open <index_name>"
    info "Opening index '${INDEX}'..."
    RESULT=$(es_request POST "/${INDEX}/_open")
    if echo "$RESULT" | grep -q '"acknowledged" *: *true'; then
      ok "Index '${INDEX}' opened"
    else
      die "Failed: $RESULT"
    fi
    ;;

  refresh)
    [[ -z "$INDEX" ]] && die "Usage: $0 refresh <index_name>"
    es_request POST "/${INDEX}/_refresh" > /dev/null
    ok "Index '${INDEX}' refreshed"
    ;;

  forcemerge)
    [[ -z "$INDEX" ]] && die "Usage: $0 forcemerge <index_name> [--segments N]"
    info "Force-merging '${INDEX}' to ${SEGMENTS} segment(s)..."
    es_request POST "/${INDEX}/_forcemerge?max_num_segments=${SEGMENTS}" > /dev/null
    ok "Force merge complete for '${INDEX}'"
    ;;

  *)
    echo "Elasticsearch Index Management Tool"
    echo ""
    echo "Usage: $0 <action> <index_name> [OPTIONS]"
    echo ""
    echo "Actions: create, delete, reindex, alias, swap, info, list, close, open, refresh, forcemerge"
    echo ""
    echo "Run '$0 <action>' for action-specific help."
    exit 1
    ;;
esac
