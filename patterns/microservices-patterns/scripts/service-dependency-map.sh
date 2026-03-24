#!/usr/bin/env bash
# service-dependency-map.sh — Analyze a codebase to map service dependencies and API calls
#
# Usage:
#   ./service-dependency-map.sh [project-root]
#
# Scans for:
#   - HTTP client calls (fetch, axios, HttpClient, RestTemplate, etc.)
#   - gRPC client connections
#   - Message broker publish/subscribe (Kafka, RabbitMQ, SQS)
#   - Docker Compose service links and depends_on
#   - Kubernetes Service references
#
# Output: Dependency map in text format with optional DOT graph
#
# Requirements: grep, find, awk (standard Unix tools)

set -euo pipefail

PROJECT_ROOT="${1:-.}"
OUTPUT_FILE="dependency-map.txt"
DOT_FILE="dependency-map.dot"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[dependency-map]${NC} $1"; }
warn() { echo -e "${YELLOW}[warning]${NC} $1"; }

if [ ! -d "$PROJECT_ROOT" ]; then
    echo "Error: Directory '$PROJECT_ROOT' does not exist."
    echo "Usage: $0 [project-root]"
    exit 1
fi

log "Scanning project root: $(cd "$PROJECT_ROOT" && pwd)"

# Initialize output
cat > "$OUTPUT_FILE" <<'HEADER'
=============================================================
  MICROSERVICES DEPENDENCY MAP
=============================================================
HEADER

echo "digraph dependencies {" > "$DOT_FILE"
echo '  rankdir=LR;' >> "$DOT_FILE"
echo '  node [shape=box, style=filled, fillcolor="#e8f4fd"];' >> "$DOT_FILE"

declare -A SERVICES
declare -A DEPS

# --- 1. Discover services from Docker Compose ---
log "Scanning Docker Compose files..."
while IFS= read -r compose_file; do
    log "  Found: $compose_file"
    # Extract service names (lines with no leading whitespace indentation matching 'servicename:')
    while IFS= read -r svc; do
        svc_clean=$(echo "$svc" | sed 's/://;s/^[[:space:]]*//')
        if [ -n "$svc_clean" ]; then
            SERVICES["$svc_clean"]=1
        fi
    done < <(grep -E '^  [a-zA-Z][a-zA-Z0-9_-]+:' "$compose_file" 2>/dev/null | head -50 || true)

    # Extract depends_on relationships
    current_svc=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^  [a-zA-Z][a-zA-Z0-9_-]+:'; then
            current_svc=$(echo "$line" | sed 's/://;s/^[[:space:]]*//')
        elif echo "$line" | grep -qE '^\s+- ' && [ -n "$current_svc" ]; then
            dep=$(echo "$line" | sed 's/^[[:space:]]*- //;s/[[:space:]]*$//')
            if [ -n "$dep" ] && [ "$dep" != "$current_svc" ]; then
                DEPS["$current_svc -> $dep"]=1
            fi
        fi
    done < <(sed -n '/depends_on/,/^  [a-zA-Z]/p' "$compose_file" 2>/dev/null || true)
done < <(find "$PROJECT_ROOT" -maxdepth 4 -name "docker-compose*.yml" -o -name "docker-compose*.yaml" 2>/dev/null)

# --- 2. Discover services from Kubernetes manifests ---
log "Scanning Kubernetes manifests..."
while IFS= read -r k8s_file; do
    while IFS= read -r svc; do
        if [ -n "$svc" ]; then
            SERVICES["$svc"]=1
        fi
    done < <(grep -A1 'kind: Service' "$k8s_file" 2>/dev/null | grep 'name:' | awk '{print $2}' | head -20 || true)
done < <(find "$PROJECT_ROOT" -maxdepth 5 \( -name "*.yml" -o -name "*.yaml" \) -path "*/k8s/*" 2>/dev/null; \
         find "$PROJECT_ROOT" -maxdepth 5 \( -name "*.yml" -o -name "*.yaml" \) -path "*/kubernetes/*" 2>/dev/null; \
         find "$PROJECT_ROOT" -maxdepth 5 \( -name "*.yml" -o -name "*.yaml" \) -path "*/manifests/*" 2>/dev/null)

# --- 3. Scan for HTTP client calls ---
log "Scanning for HTTP client calls..."
{
    echo ""
    echo "--- HTTP Client Calls ---"
} >> "$OUTPUT_FILE"

http_patterns='(fetch|axios|HttpClient|RestTemplate|WebClient|http\.get|http\.post|http\.put|http\.delete|requests\.(get|post|put|delete)|urllib|httpx|got\(|superagent|ky\.)'
while IFS= read -r match; do
    echo "  $match" >> "$OUTPUT_FILE"
done < <(grep -rn --include="*.ts" --include="*.js" --include="*.java" --include="*.py" --include="*.go" --include="*.cs" \
    -E "$http_patterns" "$PROJECT_ROOT" 2>/dev/null | head -100 || true)

# --- 4. Scan for service URL references ---
log "Scanning for service URL references..."
{
    echo ""
    echo "--- Service URL References ---"
} >> "$OUTPUT_FILE"

url_patterns='(https?://[a-zA-Z0-9_-]+[-:]|SERVICE_URL|_HOST|_ENDPOINT|_BASE_URL|_API_URL)'
while IFS= read -r match; do
    echo "  $match" >> "$OUTPUT_FILE"
    # Try to extract the target service name
    target=$(echo "$match" | grep -oE 'https?://[a-zA-Z0-9_-]+' | sed 's|https\?://||' | head -1)
    if [ -n "$target" ] && [ "$target" != "localhost" ] && [ "$target" != "127" ]; then
        source_file=$(echo "$match" | cut -d: -f1)
        source_svc=$(basename "$(dirname "$source_file")")
        DEPS["$source_svc -> $target"]="url_ref"
    fi
done < <(grep -rn --include="*.ts" --include="*.js" --include="*.java" --include="*.py" --include="*.go" --include="*.env" --include="*.yml" --include="*.yaml" \
    -E "$url_patterns" "$PROJECT_ROOT" 2>/dev/null | grep -v node_modules | grep -v '.git/' | head -100 || true)

# --- 5. Scan for message broker usage ---
log "Scanning for message broker patterns..."
{
    echo ""
    echo "--- Message Broker References ---"
} >> "$OUTPUT_FILE"

broker_patterns='(KafkaProducer|KafkaConsumer|@KafkaListener|kafka\.produce|kafka\.consume|amqplib|RabbitMQ|channel\.(publish|consume|sendToQueue)|SQS|SNS|EventBridge|NATS|\.publish\(|\.subscribe\()'
while IFS= read -r match; do
    echo "  $match" >> "$OUTPUT_FILE"
done < <(grep -rn --include="*.ts" --include="*.js" --include="*.java" --include="*.py" --include="*.go" --include="*.cs" \
    -E "$broker_patterns" "$PROJECT_ROOT" 2>/dev/null | grep -v node_modules | grep -v '.git/' | head -100 || true)

# --- 6. Scan for gRPC references ---
log "Scanning for gRPC references..."
{
    echo ""
    echo "--- gRPC References ---"
} >> "$OUTPUT_FILE"

grpc_patterns='(grpc\.|\.proto|GrpcChannel|ManagedChannelBuilder|grpc\.dial|grpc\.insecure_channel|@GrpcClient)'
while IFS= read -r match; do
    echo "  $match" >> "$OUTPUT_FILE"
done < <(grep -rn --include="*.ts" --include="*.js" --include="*.java" --include="*.py" --include="*.go" --include="*.cs" \
    -E "$grpc_patterns" "$PROJECT_ROOT" 2>/dev/null | grep -v node_modules | grep -v '.git/' | head -50 || true)

# --- 7. Generate summary ---
{
    echo ""
    echo "============================================================="
    echo "  DISCOVERED SERVICES"
    echo "============================================================="
    for svc in "${!SERVICES[@]}"; do
        echo "  • $svc"
    done

    echo ""
    echo "============================================================="
    echo "  DEPENDENCY RELATIONSHIPS"
    echo "============================================================="
    for dep in "${!DEPS[@]}"; do
        echo "  $dep"
    done

    echo ""
    echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
} >> "$OUTPUT_FILE"

# --- 8. Generate DOT graph ---
for dep in "${!DEPS[@]}"; do
    from=$(echo "$dep" | awk -F' -> ' '{print $1}')
    to=$(echo "$dep" | awk -F' -> ' '{print $2}')
    echo "  \"$from\" -> \"$to\";" >> "$DOT_FILE"
done
echo "}" >> "$DOT_FILE"

log "Results written to:"
echo -e "  ${GREEN}$OUTPUT_FILE${NC} (text report)"
echo -e "  ${GREEN}$DOT_FILE${NC} (Graphviz DOT — render with: dot -Tpng $DOT_FILE -o dependency-map.png)"
echo ""
log "Summary: ${#SERVICES[@]} services, ${#DEPS[@]} dependency relationships found"
