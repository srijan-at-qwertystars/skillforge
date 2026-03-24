#!/usr/bin/env bash
set -euo pipefail

# purge-queues.sh — Safely purge RabbitMQ queues by vhost and pattern
# Usage: ./purge-queues.sh [--vhost /] [--pattern ".*"] [--force] [--api URL]

API_URL="${RABBITMQ_API_URL:-http://localhost:15672}"
API_USER="${RABBITMQ_USER:-guest}"
API_PASS="${RABBITMQ_PASS:-guest}"
VHOST="/"
PATTERN=".*"
FORCE=false
DRY_RUN=false
USE_API=false
MIN_MESSAGES=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Safely purge RabbitMQ queues with confirmation.

Options:
  --vhost <vhost>     Target vhost (default: /)
  --pattern <regex>   Queue name regex filter (default: .* = all)
  --force             Skip confirmation prompt
  --dry-run           Show what would be purged without purging
  --min-messages <n>  Only purge queues with at least N messages (default: 0)
  --api <url>         Management API URL (default: http://localhost:15672)
  --user <user>       API username (default: guest, or \$RABBITMQ_USER)
  --pass <pass>       API password (default: guest, or \$RABBITMQ_PASS)
  -h, --help          Show this help

Examples:
  $(basename "$0") --vhost /production --pattern "^dead-letter" --dry-run
  $(basename "$0") --pattern "test\\." --force
  $(basename "$0") --vhost / --min-messages 1000

Environment variables:
  RABBITMQ_API_URL   Management API URL
  RABBITMQ_USER      API username
  RABBITMQ_PASS      API password

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --vhost)        VHOST="$2"; shift 2 ;;
        --pattern)      PATTERN="$2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --min-messages) MIN_MESSAGES="$2"; shift 2 ;;
        --api)          API_URL="$2"; USE_API=true; shift 2 ;;
        --user)         API_USER="$2"; shift 2 ;;
        --pass)         API_PASS="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# URL-encode vhost
VHOST_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${VHOST}', safe=''))" 2>/dev/null || echo "%2F")

# Detect available method
if [[ "${USE_API}" == "false" ]] && command -v rabbitmqctl &>/dev/null; then
    MODE="cli"
else
    MODE="api"
fi

echo -e "${BOLD}RabbitMQ Queue Purge Tool${NC}"
echo "Mode: ${MODE} | Vhost: ${VHOST} | Pattern: ${PATTERN}"
echo ""

# ─── Get matching queues ───
get_queues() {
    if [[ "${MODE}" == "cli" ]]; then
        rabbitmqctl list_queues -p "${VHOST}" name messages type --formatter=json 2>/dev/null | \
            python3 -c "
import sys, json, re
pattern = re.compile(r'${PATTERN}')
min_msgs = ${MIN_MESSAGES}
queues = json.load(sys.stdin)
matched = [q for q in queues if pattern.search(q['name']) and q.get('messages', 0) >= min_msgs]
json.dump(matched, sys.stdout)
"
    else
        curl -sf -u "${API_USER}:${API_PASS}" "${API_URL}/api/queues/${VHOST_ENCODED}" 2>/dev/null | \
            python3 -c "
import sys, json, re
pattern = re.compile(r'${PATTERN}')
min_msgs = ${MIN_MESSAGES}
queues = json.load(sys.stdin)
matched = [{'name': q['name'], 'messages': q.get('messages', 0), 'type': q.get('type', 'classic')}
           for q in queues if pattern.search(q['name']) and q.get('messages', 0) >= min_msgs]
json.dump(matched, sys.stdout)
"
    fi
}

# ─── Purge a single queue ───
purge_queue() {
    local queue_name="$1"

    if [[ "${MODE}" == "cli" ]]; then
        rabbitmqctl purge_queue -p "${VHOST}" "${queue_name}" 2>/dev/null
    else
        local queue_encoded
        queue_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${queue_name}', safe=''))")
        curl -sf -u "${API_USER}:${API_PASS}" -X DELETE \
            "${API_URL}/api/queues/${VHOST_ENCODED}/${queue_encoded}/contents" 2>/dev/null
    fi
}

# ─── Main ───
QUEUES_JSON=$(get_queues)

if [[ -z "${QUEUES_JSON}" || "${QUEUES_JSON}" == "[]" ]]; then
    echo "No queues match the criteria."
    exit 0
fi

QUEUE_COUNT=$(echo "${QUEUES_JSON}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
TOTAL_MESSAGES=$(echo "${QUEUES_JSON}" | python3 -c "import sys,json; print(sum(q.get('messages',0) for q in json.load(sys.stdin)))")

echo -e "Found ${BOLD}${QUEUE_COUNT}${NC} matching queues with ${BOLD}${TOTAL_MESSAGES}${NC} total messages:"
echo ""
echo "${QUEUES_JSON}" | python3 -c "
import sys, json
queues = sorted(json.load(sys.stdin), key=lambda q: q.get('messages', 0), reverse=True)
print(f'  {\"Queue\":<50} {\"Messages\":>10} {\"Type\":<10}')
print(f'  {\"-\"*50} {\"-\"*10} {\"-\"*10}')
for q in queues:
    name = q['name'][:50]
    msgs = q.get('messages', 0)
    qtype = q.get('type', 'classic')
    print(f'  {name:<50} {msgs:>10,} {qtype:<10}')
"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "${YELLOW}DRY RUN — no queues were purged.${NC}"
    exit 0
fi

if [[ "${FORCE}" != "true" ]]; then
    echo -e "${RED}WARNING: This will permanently delete ${TOTAL_MESSAGES} messages from ${QUEUE_COUNT} queues.${NC}"
    echo -n "Type 'PURGE' to confirm: "
    read -r confirmation
    if [[ "${confirmation}" != "PURGE" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Purge each queue
echo ""
echo "Purging queues..."
SUCCESS=0
FAILED=0

echo "${QUEUES_JSON}" | python3 -c "import sys,json; [print(q['name']) for q in json.load(sys.stdin)]" | \
while IFS= read -r queue_name; do
    if purge_queue "${queue_name}"; then
        echo -e "  ${GREEN}✓${NC} Purged: ${queue_name}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "  ${RED}✗${NC} Failed: ${queue_name}"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo -e "${GREEN}Purge complete.${NC}"
